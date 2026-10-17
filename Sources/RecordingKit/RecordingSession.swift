import AppKit
import AVFoundation
import ScreenCaptureKit
import ShotcraftCore

/// One recording from the moment the area is confirmed until the file is handed to `MediaPipeline`.
/// Owns the capture engine and every overlay shown while recording.
@MainActor
final class RecordingSession {
    let kind: RecordingKind
    /// Global Cocoa rect, clipped to `screen`.
    let area: CGRect
    let screen: NSScreen

    private var engine: CaptureEngine?
    private var engineConfig: CaptureEngineConfig?
    private var clock = RecordingClock()
    private(set) var isPaused = false
    private var isFinishing = false
    private let pixelSize: CGSize
    private let outputScale: CGFloat

    private let dim: DimOverlay
    private var decoration: DecorationWindow?
    private var clicks: ClickHighlighter?
    private var keys: KeystrokeOverlay?
    private var camera: CameraOverlay?
    private var controls: RecordingControlsPanel?
    private var cursorWatcher: CursorIdleWatcher?
    private var tickTimer: Timer?
    private var diskTimer: Timer?
    private var gifTask: Task<Void, Never>?
    private var gifPopup: GIFProcessingPopup?

    /// Called once when recording stops (the file may still be finalizing / converting).
    var onStop: ((RecordingSession) -> Void)?
    /// Called once when the session is completely done (delivered, deleted or failed).
    var onEnd: ((RecordingSession) -> Void)?

    init(kind: RecordingKind, area: CGRect, screen: NSScreen, camera: CameraOverlay?) {
        self.kind = kind
        self.screen = screen
        let clipped = area.intersection(screen.frame).integral
        self.area = clipped.isEmpty ? screen.frame : clipped
        self.camera = camera

        var scale = Defaults[.scaleRetinaVideosTo1x] ? 1 : screen.backingScaleFactor
        if kind == .gif, Defaults[.gifMaxWidth] > 0, self.area.width >= CGFloat(Defaults[.gifMaxWidth]) { scale = 1 }
        let dims = RecordingMath.evenPixelSize(points: self.area.size, scale: scale)
        pixelSize = CGSize(width: dims.width, height: dims.height)
        outputScale = scale

        dim = DimOverlay(area: self.area, dimmed: Defaults[.recordDimScreen])
        dim.show()
        if kind == .video && (Defaults[.recordHighlightClicks] || Defaults[.recordShowKeystrokes]) || kind == .gif && Defaults[.recordHighlightClicks] {
            let d = DecorationWindow(screen: screen)
            d.show()
            decoration = d
        }
    }

    var elapsedString: String { RecordingMath.formatElapsed(clock.elapsed()) }

    // MARK: Start

    func start() async throws {
        let config = try await makeEngineConfig()
        engineConfig = config
        try await launchEngine(config)

        if let decoration {
            if Defaults[.recordHighlightClicks] { let c = ClickHighlighter(host: decoration); c.start(); clicks = c }
            if kind == .video && Defaults[.recordShowKeystrokes] { let k = KeystrokeOverlay(host: decoration, area: area); k.start(); keys = k }
        }
        if Defaults[.recordShowCursor] && Defaults[.recordHideCursorWhenNotMoving] {
            let w = CursorIdleWatcher { [weak self] visible in self?.engine?.setShowsCursor(visible) }
            w.start()
            cursorWatcher = w
        }
        let controls = RecordingControlsPanel(area: area, screen: screen, actions: .init(
            stop: { [weak self] in self?.stop() },
            togglePause: { [weak self] in self?.togglePause() },
            restart: { [weak self] in self?.restart() },
            delete: { [weak self] in self?.delete() }))
        self.controls = controls
        if Defaults[.recordShowControls] { controls.show() }

        Sound.play(.recordStart)
        clock.start()
        StatusBar.setRecording(true, elapsedString)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        diskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDiskSpace() }
        }
    }

    private func launchEngine(_ config: CaptureEngineConfig) async throws {
        let engine = CaptureEngine(config: config)
        engine.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.engineFailed(error) }
            }
        }
        self.engine = engine
        try await engine.start()
    }

    private func makeEngineConfig() async throws -> CaptureEngineConfig {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw ScreenCapturer.CaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        // Our decorative overlays are burned into the video; every other Shotcraft window is excluded.
        let keep = Set([decoration?.window.windowNumber, camera?.windowNumber].compactMap { $0 }.map { CGWindowID($0) })
        let excepted = content.windows.filter { keep.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: excepted)

        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        var local = ScreenGeometry.displayLocalRect(area, on: screen)
        local.size = CGSize(width: pixelSize.width / outputScale, height: pixelSize.height / outputScale)

        let isVideo = kind == .video
        let quality: VideoQuality = isVideo ? Defaults[.videoQuality] : .high
        let fps = isVideo ? max(1, Defaults[.videoFPS]) : RecordingMath.clampedGIFFPS(Defaults[.gifFPS])
        let codec: RecordingMath.Codec = isVideo ? RecordingMath.codec(for: quality, width: w, height: h)
                                                 : (w > 4096 || h > 4096 ? .hevc : .h264)
        let format = Defaults[.videoFormat]
        let mode: CaptureMode = isVideo ? .recording : .gifRecording
        let name = FileNameTemplate.render(Defaults[.fileNameTemplate], kind: mode.fileNameKind)
        let url = isVideo
            ? AppPaths.uniqueURL(AppPaths.recordings.appendingPathComponent(name).appendingPathExtension(format.fileExtension))
            : AppPaths.temporary.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        gifName = name

        var micID: String?
        if isVideo, Defaults[.recordMicrophone] {
            if Permissions.status(for: .audio) == .authorized, let mic = AVDevices.selectedMicrophone {
                micID = mic.uniqueID
            } else {
                HUD.show("No microphone was selected for this recording.", symbol: "mic.slash")
            }
        }

        return CaptureEngineConfig(
            outputURL: url, fileType: isVideo && format == .mov ? .mov : .mp4, codec: codec,
            pixelWidth: w, pixelHeight: h, fps: fps,
            bitrate: RecordingMath.videoBitrate(width: w, height: h, fps: fps, quality: quality),
            showsCursor: Defaults[.recordShowCursor], systemAudio: isVideo && Defaults[.recordSystemAudio],
            microphoneID: micID, mono: Defaults[.recordAudioMono], filter: filter, sourceRect: local)
    }

    private var gifName = ""

    // MARK: Controls

    private func tick() {
        let text = elapsedString
        controls?.update(elapsed: text, paused: isPaused)
        StatusBar.setRecording(true, text)
    }

    func togglePause() {
        guard !isFinishing, let engine else { return }
        isPaused.toggle()
        engine.setPaused(isPaused)
        if isPaused { clock.pause() } else { clock.resume() }
        Sound.play(.recordPause)
        tick()
    }

    func restart() {
        guard !isFinishing, let engine, let config = engineConfig else { return }
        isFinishing = true
        Task { @MainActor in
            await engine.cancel()
            do {
                try await launchEngine(config)
                if isPaused { isPaused = false }
                clock.start()
                isFinishing = false
                Sound.play(.recordStart)
                tick()
            } catch {
                Alerts.error("An error occurred while starting screen recording.", error)
                tearDownOverlays()
                end()
            }
        }
    }

    func delete() {
        guard !isFinishing else { return }
        let wasPaused = isPaused
        if !wasPaused { togglePause() }
        guard Alerts.confirm("Are you sure you want to delete this recording?", confirmTitle: "Delete", destructive: true) else {
            if !wasPaused { togglePause() }
            return
        }
        isFinishing = true
        tearDownOverlays()
        notifyStopped()
        let engine = self.engine
        Task { @MainActor in
            await engine?.cancel()
            end()
        }
    }

    /// Discards before anything was recorded (countdown cancelled).
    func discard() {
        isFinishing = true
        tearDownOverlays()
        camera?.close()
        end()
    }

    private func checkDiskSpace() {
        let values = try? AppPaths.recordings.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage,
              RecordingMath.isDiskNearlyFull(availableBytes: available) else { return }
        stop()
        Alerts.error("Recording stopped because your disk is almost full.")
    }

    private func engineFailed(_ error: Error) {
        guard !isFinishing else { return }
        Log.recording.error("Recording failed: \(error.localizedDescription, privacy: .public)")
        stop(failure: error)
    }

    // MARK: Stop

    func stop(failure: Error? = nil) {
        guard !isFinishing, let engine else { return }
        isFinishing = true
        Sound.play(.recordStop)
        tearDownOverlays()
        notifyStopped()
        Task { @MainActor in
            do {
                let url = try await engine.finish()
                if let failure { HUD.show(failure.localizedDescription, symbol: "exclamationmark.triangle.fill", duration: 3) }
                if kind == .gif { convertToGIF(url) } else { deliver(url, kind: .video, size: pixelSize, scale: outputScale) }
            } catch {
                Alerts.error("An error occurred with screen recording.", failure ?? error)
                end()
            }
        }
    }

    private func convertToGIF(_ video: URL) {
        let output = AppPaths.uniqueURL(AppPaths.recordings.appendingPathComponent(gifName).appendingPathExtension("gif"))
        let popup = GIFProcessingPopup { [weak self] in self?.gifTask?.cancel() }
        gifPopup = popup
        popup.show()
        let areaWidth = area.width
        gifTask = Task { @MainActor [weak self] in
            defer { try? FileManager.default.removeItem(at: video) }
            do {
                let size = try await GIFEncoder.convert(video: video, to: output, fps: Defaults[.gifFPS],
                                                        maxWidth: Defaults[.gifMaxWidth]) { p in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.gifPopup?.setProgress(p) } }
                }
                popup.close()
                self?.deliver(output, kind: .gif, size: size, scale: max(1, size.width / max(1, areaWidth)))
            } catch {
                popup.close()
                try? FileManager.default.removeItem(at: output)
                if case GIFError.cancelled = error {} else { Alerts.error("An error occurred while processing the video file.", error) }
                self?.end()
            }
        }
    }

    private func deliver(_ url: URL, kind: MediaKind, size: CGSize, scale: CGFloat) {
        MediaPipeline.didFinishRecording(url: url, kind: kind, mode: kind == .gif ? .gifRecording : .recording,
                                         pixelSize: size, scale: scale)
        end()
    }

    private func tearDownOverlays() {
        tickTimer?.invalidate(); tickTimer = nil
        diskTimer?.invalidate(); diskTimer = nil
        cursorWatcher?.stop(); cursorWatcher = nil
        clicks?.stop(); clicks = nil
        keys?.stop(); keys = nil
        decoration?.close(); decoration = nil
        controls?.close(); controls = nil
        camera?.close(); camera = nil
        dim.close()
        StatusBar.setRecording(false, nil)
    }

    private func notifyStopped() {
        let handler = onStop
        onStop = nil
        handler?(self)
    }

    private func end() {
        gifPopup = nil
        gifTask = nil
        let handler = onEnd
        onEnd = nil
        handler?(self)
    }
}
