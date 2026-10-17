import AppKit
import AVFoundation
import AVKit
import ShotcraftCore

/// Window that toggles playback with Space unless a text field is being edited.
final class EditorWindow: NSWindow {
    var onSpace: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, !(firstResponder is NSTextView) { onSpace?(); return }
        super.keyDown(with: event)
    }
}

/// Builds the bottom-bar button style shared by both editors.
@MainActor
func editorButton(_ title: String, symbolName: String?, target: AnyObject, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .push
    if let symbolName { b.image = symbol(symbolName, size: 13); b.imagePosition = .imageLeading }
    return b
}

/// The VideoTrimmer / VideoPopup equivalent: trim, strip audio, re-encode, convert to GIF.
@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate, MediaEditor {
    let media: CapturedMedia
    var onClose: (() -> Void)?

    private let playerView = AVPlayerView()
    private let player = AVPlayer()
    private let qualityPopup = NSPopUpButton()
    private let scalePopup = NSPopUpButton()
    private let estimateLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private var actionButtons: [NSButton] = []

    // Source facts.
    private var duration: Double = 0
    private var fps = 30
    private var audioTrackCount = 0
    private var fileBytes: Int64 = 0
    private var naturalSize: CGSize = .zero

    // Pending edits.
    private var removeAudio = false
    private var exportTask: Task<Void, Never>?

    init(media: CapturedMedia) {
        self.media = media
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.onSpace = { [weak self] in self?.togglePlay() }
        buildUI()
        loadMedia()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.translatesAutoresizingMaskIntoConstraints = false

        let trim = editorButton("Trim", symbolName: "scissors", target: self, action: #selector(trimClicked))
        let audio = editorButton("Remove the Audio", symbolName: "speaker.slash", target: self, action: #selector(removeAudioClicked))
        for q in VideoQuality.allCases { qualityPopup.addItem(withTitle: q.displayName); qualityPopup.lastItem?.representedObject = q.rawValue }
        qualityPopup.target = self; qualityPopup.action = #selector(optionsChanged)
        qualityPopup.toolTip = "Quality"
        scalePopup.target = self; scalePopup.action = #selector(optionsChanged)
        scalePopup.toolTip = "Resolution"
        estimateLabel.font = .systemFont(ofSize: 11)
        estimateLabel.textColor = .secondaryLabelColor
        let gif = editorButton("Convert to GIF", symbolName: "photo.stack", target: self, action: #selector(convertToGIFClicked))
        let saveNew = editorButton("Save as New Video", symbolName: nil, target: self, action: #selector(saveAsNewClicked))
        let save = editorButton("Save", symbolName: nil, target: self, action: #selector(saveClicked))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let cancel = editorButton("Cancel", symbolName: nil, target: self, action: #selector(cancelExport))
        cancel.isHidden = true
        actionButtons = [trim, audio, gif, saveNew, save]

        let left = NSStackView(views: [trim, audio])
        let right = NSStackView(views: [qualityPopup, scalePopup, estimateLabel, progressBar, cancel, gif, saveNew, save])
        right.spacing = 8
        let bar = NSStackView(views: [left, NSView(), right])
        bar.distribution = .fill
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let fx = NSVisualEffectView()
        fx.material = .titlebar
        fx.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)
        content.addSubview(fx)
        fx.addSubview(bar)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: fx.topAnchor),
            fx.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            fx.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fx.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: fx.leadingAnchor), bar.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            bar.topAnchor.constraint(equalTo: fx.topAnchor), bar.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        trimButton = trim
        audioButton = audio
        cancelButton = cancel
        window.initialFirstResponder = playerView
    }

    private weak var trimButton: NSButton?
    private weak var audioButton: NSButton?
    private weak var cancelButton: NSButton?

    private func loadMedia() {
        window?.title = media.url.lastPathComponent
        window?.representedURL = media.url
        removeAudio = false
        player.isMuted = false
        let asset = AVURLAsset(url: media.url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        fileBytes = Int64((try? media.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        Task { @MainActor in
            do {
                duration = try await asset.load(.duration).seconds
                if let v = try await asset.loadTracks(withMediaType: .video).first {
                    let (size, t, rate) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                    let r = size.applying(t)
                    naturalSize = CGSize(width: abs(r.width), height: abs(r.height))
                    fps = max(1, Int(rate.rounded()))
                }
                audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
            } catch {
                Alerts.error("An error occurred while processing the video file.", error)
            }
            rebuildScaleMenu()
            refreshState()
        }
    }

    private func rebuildScaleMenu() {
        let selected = Defaults[.rkExportScale]
        scalePopup.removeAllItems()
        for f in [1.0, 0.75, 0.5, 0.25] {
            let d = RecordingMath.evenPixelSize(points: naturalSize, scale: f)
            scalePopup.addItem(withTitle: "\(Int(f * 100))%  (\(d.width) × \(d.height))")
            scalePopup.lastItem?.representedObject = f
            if abs(f - selected) < 0.01 { scalePopup.select(scalePopup.lastItem) }
        }
        if let q = qualityPopup.itemArray.first(where: { ($0.representedObject as? String) == Defaults[.rkExportQuality].rawValue }) {
            qualityPopup.select(q)
        }
    }

    private var options: VideoExportOptions {
        let q = (qualityPopup.selectedItem?.representedObject as? String).flatMap(VideoQuality.init(rawValue:)) ?? .original
        let s = scalePopup.selectedItem?.representedObject as? Double ?? 1
        return VideoExportOptions(timeRange: trimRange, removeAudio: removeAudio, quality: q, scale: s,
                                  fileType: VideoExporter.fileType(for: media.url))
    }

    /// The range chosen in AVPlayerView's trimming UI (whole file when untrimmed).
    private var trimRange: CMTimeRange {
        let full = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        guard let item = player.currentItem else { return full }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : full.end
        return CMTimeRange(start: start, end: end).intersection(full)
    }

    private var isTrimmed: Bool { abs(trimRange.duration.seconds - duration) > 0.01 }
    private var hasPendingEdits: Bool { isTrimmed || removeAudio }

    private func refreshState() {
        let o = options
        let bytes = VideoExporter.estimatedSize(sourceBytes: fileBytes, sourceDuration: duration, options: o,
                                                pixelSize: naturalSize, fps: fps, audioTracks: audioTrackCount)
        estimateLabel.stringValue = "Estimated file size: \(RecordingMath.formattedByteCount(bytes))"
        audioButton?.isEnabled = audioTrackCount > 0 && !removeAudio
        audioButton?.toolTip = audioTrackCount == 0 ? "This video has no audio." : nil
        trimButton?.title = isTrimmed ? "Trim (\(RecordingMath.formatElapsed(trimRange.duration.seconds)))" : "Trim"
        window?.isDocumentEdited = hasPendingEdits
    }

    private func setBusy(_ busy: Bool) {
        actionButtons.forEach { $0.isEnabled = !busy }
        qualityPopup.isEnabled = !busy
        scalePopup.isEnabled = !busy
        progressBar.isHidden = !busy
        cancelButton?.isHidden = !busy
        estimateLabel.isHidden = busy
        progressBar.doubleValue = 0
        if !busy { refreshState() }
    }

    // MARK: Actions

    private func togglePlay() {
        if player.rate == 0 {
            if let item = player.currentItem, item.currentTime() >= trimRange.end - CMTime(value: 1, timescale: 30) {
                player.seek(to: trimRange.start)
            }
            player.play()
        } else {
            player.pause()
        }
    }

    @objc private func trimClicked() {
        guard playerView.canBeginTrimming else { return }
        player.pause()
        playerView.beginTrimming { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        }
    }

    @objc private func removeAudioClicked() {
        guard audioTrackCount > 0 else { HUD.show("This video has no audio.", symbol: "speaker.slash"); return }
        guard Alerts.confirm("Are you sure you want to remove the audio track?", confirmTitle: "Remove the Audio", destructive: true) else { return }
        removeAudio = true
        player.isMuted = true
        refreshState()
    }

    @objc private func optionsChanged() {
        if let q = (qualityPopup.selectedItem?.representedObject as? String).flatMap(VideoQuality.init(rawValue:)) { Defaults[.rkExportQuality] = q }
        if let s = scalePopup.selectedItem?.representedObject as? Double { Defaults[.rkExportScale] = s }
        refreshState()
    }

    @objc private func cancelExport() { exportTask?.cancel() }

    @objc private func saveClicked() {
        guard Alerts.confirm("Do you want to replace the existing video?", confirmTitle: "Replace") else { return }
        save(replacing: true, then: nil)
    }

    @objc private func saveAsNewClicked() { save(replacing: false, then: nil) }

    /// Exports with the current options. Replacing writes over `media.url`; otherwise a new capture is added.
    private func save(replacing: Bool, then: (() -> Void)?) {
        let o = options
        let source = media.url
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let dir = source.deletingLastPathComponent()
        let target = replacing ? AppPaths.temporary.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                               : AppPaths.uniqueURL(dir.appendingPathComponent("\(stem) (edited)").appendingPathExtension(ext))
        setBusy(true)
        exportTask = Task { @MainActor [weak self] in
            do {
                let size = try await VideoExporter.export(source: source, options: o, to: target) { p in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.progressBar.doubleValue = p } }
                }
                guard let self else { return }
                let scale = max(1, self.media.scale * CGFloat(o.scale))
                if replacing {
                    self.player.replaceCurrentItem(with: nil)
                    _ = try FileManager.default.replaceItemAt(source, withItemAt: target)
                    self.media.pixelSize = size
                    self.media.scale = scale
                    self.media.notifyChanged()
                    self.loadMedia()
                } else {
                    let new = CapturedMedia(url: target, kind: .video, mode: self.media.mode, pixelSize: size, scale: scale)
                    MediaPipeline.ingest(new, actions: [.showQuickAccess])
                }
                self.setBusy(false)
                HUD.show(replacing ? "Video saved" : "Saved as new video")
                then?()
            } catch {
                try? FileManager.default.removeItem(at: target)
                self?.setBusy(false)
                if case VideoExportError.cancelled = error { return }
                Alerts.error("The video cannot be trimmed. Please try again.", error)
            }
        }
    }

    @objc private func convertToGIFClicked() {
        let range = trimRange
        let source = media.url
        let name = source.deletingPathExtension().lastPathComponent
        let output = AppPaths.uniqueURL(AppPaths.recordings.appendingPathComponent(name).appendingPathExtension("gif"))
        let scale = media.scale
        setBusy(true)
        exportTask = Task { @MainActor [weak self] in
            do {
                let size = try await GIFEncoder.convert(video: source, to: output, timeRange: range, fps: Defaults[.gifFPS],
                                                        maxWidth: Defaults[.gifMaxWidth]) { p in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.progressBar.doubleValue = p } }
                }
                let gifScale = max(1, scale * size.width / max(1, self?.naturalSize.width ?? size.width))
                let gif = CapturedMedia(url: output, kind: .gif, mode: .gifRecording, pixelSize: size, scale: gifScale)
                MediaPipeline.ingest(gif, actions: [.showQuickAccess])
                self?.setBusy(false)
            } catch {
                try? FileManager.default.removeItem(at: output)
                self?.setBusy(false)
                if case GIFError.cancelled = error { return }
                Alerts.error("An error occurred while processing the video file.", error)
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if exportTask != nil, !progressBar.isHidden { NSSound.beep(); return false }
        guard hasPendingEdits else { return true }
        let a = NSAlert()
        a.messageText = "Do you want to trim the video?"
        a.informativeText = "If you don't save, the video will not be trimmed."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let discard = a.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        switch a.runModal() {
        case .alertFirstButtonReturn:
            save(replacing: true) { [weak self] in self?.window?.close() }
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        exportTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        onClose?()
    }
}
