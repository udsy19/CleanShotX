import AppKit
import ScreenCaptureKit
import ShotcraftCore

/// Drives one Studio recording end to end: area → pre-record bar → countdown → capture → project package → editor.
@MainActor
final class StudioRecordingSession {
    enum State { case preparing, countdown, recording, finishing }

    private(set) var state: State = .preparing
    private let area: CGRect
    private let screen: NSScreen
    private let onFinish: (URL?) -> Void

    private let options = PreRecordOptions()
    private var outline: AreaOutlineWindow?
    private var preBar: StudioPanel?
    private var controls: StudioPanel?
    private let controlsModel = RecordingControlsModel()
    private var countdown: CountdownWindow?
    private var cameraBubble: CameraBubbleWindow?
    private var camera: CameraRecorder?
    private var timer: Timer?

    private var clock = RecordingClock()
    private var recorder: StudioScreenRecorder?
    private var tracker: InputTracker?
    private var workDir: URL?
    private var startedAt = Date()
    /// Identifies the current capture start-up, so a restart can't be confused with a late older start.
    private var attempt = 0

    /// - Parameters:
    ///   - area: global Cocoa rect (already clipped to one screen).
    ///   - onFinish: called with the saved package URL (nil when cancelled / failed).
    init(area: CGRect, screen: NSScreen, onFinish: @escaping (URL?) -> Void) {
        self.area = area
        self.screen = screen
        self.onFinish = onFinish
    }

    var isRecording: Bool { state == .recording }

    // MARK: Preparing

    func begin() {
        let o = AreaOutlineWindow(rect: area)
        o.orderFrontRegardless()
        outline = o

        options.onStart = { [weak self] in self?.startCountdown() }
        options.onCancel = { [weak self] in self?.cancel() }
        options.onCameraChange = { [weak self] id in self?.setCamera(id) }
        let bar = PanelFactory.panel(PreRecordBar(options: options))
        bar.onCancel = { [weak self] in self?.cancel() }
        PanelFactory.place(bar, below: area, on: screen)
        bar.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preBar = bar
        setCamera(options.cameraID)
    }

    private func setCamera(_ id: String?) {
        cameraBubble?.orderOut(nil); cameraBubble = nil
        camera?.cancel(); camera = nil
        guard let id else { return }
        let open = { [weak self] in
            guard let self, self.state == .preparing else { return }
            do {
                let cam = try CameraRecorder(deviceID: id)
                self.camera = cam
                let bubble = CameraBubbleWindow(session: cam.session, near: self.area)
                bubble.orderFrontRegardless()
                self.cameraBubble = bubble
            } catch {
                self.options.cameraID = nil
                Alerts.error("Camera device not found", error)
            }
        }
        switch Permissions.status(for: .video) {
        case .authorized: open()
        case .notDetermined: Permissions.request(.video) { ok in if ok { open() } else { self.options.cameraID = nil } }
        default:
            options.cameraID = nil
            if Alerts.confirm("Camera access required", info: "Allow Shotcraft to use the camera in System Settings → Privacy & Security → Camera.",
                              confirmTitle: "Open System Settings") { Permissions.openSettings(.camera) }
        }
    }

    private func startCountdown() {
        options.persist()
        // Microphone permission must be settled before capture starts.
        if options.microphoneID != nil, Permissions.status(for: .audio) != .authorized {
            if Permissions.status(for: .audio) == .notDetermined {
                Permissions.request(.audio) { [weak self] ok in
                    if !ok { self?.options.microphoneID = nil }
                    self?.startCountdown()
                }
                return
            }
            options.microphoneID = nil
        }
        if options.keystrokes && !Permissions.hasAccessibility { Permissions.requestAccessibility() }
        preBar?.orderOut(nil)
        state = .countdown
        let cd = CountdownWindow()
        countdown = cd
        cd.run(seconds: Defaults[.recordCountdown] ? Defaults[.recordCountdownSeconds] : 0, over: area) { [weak self] ok in
            guard let self else { return }
            self.countdown = nil
            if ok { self.startCapture() } else { self.state = .preparing; self.preBar?.makeKeyAndOrderFront(nil) }
        }
    }

    // MARK: Recording

    private func startCapture() {
        state = .recording
        attempt += 1
        let attempt = attempt
        let dir = AppPaths.temporary.appendingPathComponent("studio-\(UUID().uuidString)", isDirectory: true)
        AppPaths.ensure(dir)
        workDir = dir
        let package = StudioPackage(url: dir)
        clock = RecordingClock()
        let scale = screen.backingScaleFactor
        let local = ScreenGeometry.displayLocalRect(area, on: screen)
        let displayID = screen.displayID
        let fps = max(30, min(60, Defaults[.videoFPS]))
        let micID = options.microphoneID
        let systemAudio = options.systemAudio
        let mono = Defaults[.recordAudioMono]
        let tracker = InputTracker(area: area, clock: clock)
        self.tracker = tracker
        let clock = self.clock

        Task { @MainActor in
            do {
                let content = try await ScreenCapturer.shareableContent()
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenCapturer.CaptureError.noDisplay }
                let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let cfg = StudioScreenRecorder.Config(
                    url: package.screenURL, filter: filter, sourceRect: local,
                    pixelWidth: Int((local.width * scale / 2).rounded()) * 2, pixelHeight: Int((local.height * scale / 2).rounded()) * 2,
                    fps: fps, systemAudio: systemAudio, microphoneID: micID, mono: mono)
                let rec = StudioScreenRecorder(config: cfg, clock: clock)
                rec.onFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.state == .recording else { return }
                        Log.recording.error("Studio capture failed: \(error.localizedDescription, privacy: .public)")
                        self.stop()
                    }
                }
                self.recorder = rec
                try await rec.start()
                guard self.state == .recording, self.attempt == attempt else { await rec.cancel(); return }
                clock.start()
                self.startedAt = Date()
                tracker.start(recordKeys: self.options.keystrokes)
                self.camera?.record(to: package.cameraURL, clock: clock)
                Sound.play(.recordStart)
                self.outline?.setRecording(true)
                self.showControls()
            } catch {
                // Stopped/restarted while starting up: that path already cleaned up.
                guard self.state == .recording, self.attempt == attempt else { return }
                self.state = .finishing
                await self.recorder?.cancel()
                _ = self.tracker?.finish()
                self.teardownUI()
                self.camera?.cancel()
                try? FileManager.default.removeItem(at: dir)
                Alerts.error("Screen Recording stopped unexpectedly.", error)
                self.onFinish(nil)
            }
        }
    }

    private func showControls() {
        controlsModel.paused = false
        controlsModel.elapsed = "0:00"
        controlsModel.onStop = { [weak self] in self?.stop() }
        controlsModel.onPauseResume = { [weak self] in self?.togglePause() }
        controlsModel.onRestart = { [weak self] in self?.restart() }
        controlsModel.onDelete = { [weak self] in self?.deleteRecording() }
        if controls == nil {
            let p = PanelFactory.panel(RecordingControlsBar(model: controlsModel))
            PanelFactory.place(p, below: area, on: screen)
            controls = p
        }
        if Defaults[.recordShowControls] { controls?.orderFrontRegardless() }
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickTimer() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tickTimer()
    }

    private func tickTimer() {
        let e = TimeFormat.string(clock.elapsed(), tenths: false)
        controlsModel.elapsed = e
        StatusBar.setRecording(true, Defaults[.recordShowTimeInMenuBar] ? e : nil)
    }

    func togglePause() {
        guard state == .recording else { return }
        if clock.isPaused { clock.resume(); Sound.play(.recordStart) } else { clock.pause(); Sound.play(.recordPause) }
        controlsModel.paused = clock.isPaused
    }

    private func restart() {
        guard state == .recording,
              Alerts.confirm("Are you sure you want to cancel this recording and start a new one?", confirmTitle: "Restart") else { return }
        discardCapture { [weak self] in
            guard let self else { return }
            self.controls?.orderOut(nil)
            self.outline?.setRecording(false)
            self.startCountdown()
        }
    }

    private func deleteRecording() {
        guard state == .recording,
              Alerts.confirm("Are you sure you want to delete this recording?", info: "This operation cannot be undone.",
                             confirmTitle: "Delete", destructive: true) else { return }
        state = .finishing
        discardCapture { [weak self] in
            guard let self else { return }
            self.camera?.cancel()
            self.teardownUI()
            self.onFinish(nil)
        }
    }

    /// Stops all writers and deletes the work directory (camera session keeps running for a restart).
    private func discardCapture(then next: @escaping () -> Void) {
        attempt += 1
        timer?.invalidate(); timer = nil
        StatusBar.setRecording(false, nil)
        clock.stop()
        _ = tracker?.finish(); tracker = nil
        camera?.cancel(stopSession: false)
        let rec = recorder; recorder = nil
        let dir = workDir; workDir = nil
        Task { @MainActor in
            await rec?.cancel()
            if let dir { try? FileManager.default.removeItem(at: dir) }
            next()
        }
    }

    /// Finishes the recording and writes the project package.
    func stop() {
        guard state == .recording else { return }
        // Capture hasn't started yet (stopped from the menu bar during start-up): nothing to keep.
        guard clock.isStarted, let recorder, let workDir, let tracker else {
            state = .finishing
            discardCapture { [weak self] in
                guard let self else { return }
                self.camera?.cancel(); self.camera = nil
                self.teardownUI()
                self.onFinish(nil)
            }
            return
        }
        state = .finishing
        timer?.invalidate(); timer = nil
        clock.stop()
        let duration = clock.elapsed()
        let events = tracker.finish()
        self.tracker = nil
        Sound.play(.recordStop)
        StatusBar.setRecording(false, nil)
        teardownUI()
        let cam = camera
        camera = nil
        let package = StudioPackage(url: workDir)
        let cfg = recorder.config
        let micName = recorder.microphoneName
        let camName = cam?.deviceName
        Task { @MainActor in
            do {
                try await recorder.finish(duration: duration)
                let cameraOK: Bool = await withCheckedContinuation { cont in
                    if let cam { cam.finish { ok in cont.resume(returning: ok) } } else { cont.resume(returning: false) }
                }
                let name = FileNameTemplate.render(Defaults[.fileNameTemplate], kind: CaptureMode.studio.fileNameKind)
                let info = RecordingInfo(pixelWidth: cfg.pixelWidth, pixelHeight: cfg.pixelHeight, scale: Double(self.screen.backingScaleFactor),
                                         duration: duration, fps: cfg.fps, hasCamera: cameraOK,
                                         hasSystemAudio: cfg.systemAudio, hasMicrophone: cfg.microphoneID != nil,
                                         recordedAt: self.startedAt, cameraName: cameraOK ? camName : nil, microphoneName: micName)
                var project = StudioProject(title: name, recording: info, style: StudioStyleMemory.last)
                if project.style.zoom.autoZoom {
                    project.zooms = SmartZoomAnalyzer().analyze(clicks: events.clicks, duration: duration)
                    if project.style.zoom.followCursorByDefault {
                        for i in project.zooms.indices { project.zooms[i].mode = .followCursor }
                    }
                }
                project.style.keystrokes.show = project.style.keystrokes.show || !events.keys.isEmpty
                try package.write(events: events)
                try package.write(project: project)
                let dest = AppPaths.uniqueURL(AppPaths.projects.appendingPathComponent(name).appendingPathExtension(StudioPackage.fileExtension))
                try FileManager.default.moveItem(at: workDir, to: dest)
                self.onFinish(dest)
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                Alerts.error("Something went wrong saving your recording.", error)
                self.onFinish(nil)
            }
        }
    }

    /// Cancels before recording started.
    func cancel() {
        switch state {
        case .preparing:
            state = .finishing
            camera?.cancel(); camera = nil
            teardownUI()
            onFinish(nil)
        case .countdown:
            countdown?.finish(false)
        case .recording:
            deleteRecording()
        case .finishing:
            break
        }
    }

    private func teardownUI() {
        timer?.invalidate(); timer = nil
        for w in [preBar, controls] as [NSWindow?] { w?.orderOut(nil) }
        outline?.orderOut(nil)
        cameraBubble?.orderOut(nil)
        preBar = nil; controls = nil; outline = nil; cameraBubble = nil
    }
}
