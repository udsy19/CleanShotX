import AppKit
import AVFoundation
import AVKit
import SuperScreenshotCore

/// Video Editor for plain recordings: a left rail with the Audio panel, the player, and a trim
/// timeline; exports through the Export sheet (resolution, quality, audio, estimated size).
@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate, MediaEditor {
    let media: CapturedMedia
    var onClose: (() -> Void)?

    private let playerView = AVPlayerView()
    private let player = AVPlayer()
    private let timeline = TimelineView()
    private let audioSwitch = NSSwitch()
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeLabel = NSTextField(labelWithString: "100%")
    private let audioNote = NSTextField(wrappingLabelWithString: "")
    private var playButton: NSButton!
    private let timeLabel = EditorChrome.timeLabel()
    private let trimLabel = EditorChrome.timeLabel()
    private var titleButtons: [NSButton] = []
    private var timeObserver: Any?
    private var thumbnailTask: Task<Void, Never>?

    // Source facts.
    private var duration: Double = 0
    private var fps = 30
    private var audioTrackCount = 0
    private var fileBytes: Int64 = 0
    private var naturalSize: CGSize = .zero

    // Edits.
    private var includeAudio = true
    private var volume: Float = 1
    private var exportTask: Task<Void, Never>?
    private var exportSheet: ExportSheet?
    private var progressSheet: ExportProgressSheet?

    init(media: CapturedMedia) {
        self.media = media
        let window = EditorChrome.makeWindow(title: media.url.lastPathComponent, url: media.url,
                                             size: NSSize(width: 1000, height: 660), minSize: NSSize(width: 720, height: 460))
        super.init(window: window)
        window.delegate = self
        window.onSpace = { [weak self] in self?.togglePlay() }
        window.onMarkIn = { [weak self] in self?.markIn() }
        window.onMarkOut = { [weak self] in self?.markOut() }
        buildUI()
        loadMedia()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        // Left rail — Audio panel.
        let rail = NSVisualEffectView()
        rail.material = .sidebar
        rail.blendingMode = .behindWindow
        rail.translatesAutoresizingMaskIntoConstraints = false
        let header = NSTextField(labelWithString: "Audio")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        let includeLabel = NSTextField(labelWithString: "Include audio")
        audioSwitch.target = self
        audioSwitch.action = #selector(audioChanged)
        let includeRow = NSStackView(views: [includeLabel, NSView(), audioSwitch])
        let volumeTitle = NSTextField(labelWithString: "Volume")
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        volumeLabel.textColor = .secondaryLabelColor
        volumeLabel.alignment = .right
        let volumeRow = NSStackView(views: [volumeTitle, NSView(), volumeLabel])
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.isContinuous = true
        audioNote.font = .systemFont(ofSize: 11)
        audioNote.textColor = .secondaryLabelColor
        let railStack = NSStackView(views: [header, includeRow, volumeRow, volumeSlider, audioNote])
        railStack.orientation = .vertical
        railStack.alignment = .leading
        railStack.spacing = 10
        railStack.setCustomSpacing(14, after: header)
        railStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        railStack.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(railStack)
        for v in [includeRow, volumeRow, volumeSlider, audioNote] {
            v.widthAnchor.constraint(equalTo: railStack.widthAnchor, constant: -32).isActive = true
        }

        // Bottom — transport + timeline.
        playButton = EditorChrome.playButton(target: self, action: #selector(playClicked))
        trimLabel.alignment = .right
        let bottom = EditorChrome.bottomBar(transport: [playButton, timeLabel, NSView(), trimLabel], timeline: timeline)
        timeline.onScrub = { [weak self] t in self?.seek(to: t) }
        timeline.onTrimChange = { [weak self] _, _ in self?.refreshState() }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(rail)
        content.addSubview(divider)
        content.addSubview(playerView)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rail.topAnchor.constraint(equalTo: content.topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            rail.widthAnchor.constraint(equalToConstant: 220),
            railStack.leadingAnchor.constraint(equalTo: rail.leadingAnchor),
            railStack.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
            railStack.topAnchor.constraint(equalTo: rail.topAnchor),
            // A vertical divider gets an explicit width and its height from the rail — never an intrinsic size.
            divider.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: rail.topAnchor),
            divider.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let gif = EditorChrome.button("Convert to GIF", symbolName: "photo.stack", target: self, action: #selector(convertToGIFClicked))
        let export = EditorChrome.button("Export…", symbolName: nil, target: self, action: #selector(exportClicked))
        export.keyEquivalent = "s"
        export.keyEquivalentModifierMask = .command
        export.bezelColor = .controlAccentColor
        titleButtons = [gif, export]
        EditorChrome.addTitlebarButtons(titleButtons, to: window)
        window.initialFirstResponder = playerView

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playbackTick(time.seconds) }
        }
        updatePlayButton()
    }

    private func loadMedia() {
        window?.title = media.url.lastPathComponent
        window?.representedURL = media.url
        let asset = AVURLAsset(url: media.url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        fileBytes = Int64((try? media.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        Task { @MainActor [weak self] in
            do {
                let d = try await asset.load(.duration).seconds
                let video = try await asset.loadTracks(withMediaType: .video).first
                var size = CGSize.zero, rate: Float = 30
                if let video {
                    let (natural, t, nominal) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                    let r = natural.applying(t)
                    size = CGSize(width: abs(r.width), height: abs(r.height))
                    rate = nominal
                }
                let audioCount = try await asset.loadTracks(withMediaType: .audio).count
                guard let self else { return }
                self.duration = d.isFinite ? d : 0
                self.naturalSize = size
                self.fps = max(1, Int(rate.rounded()))
                self.audioTrackCount = audioCount
                self.timeline.duration = self.duration
                self.timeline.playhead = 0
                self.loadThumbnails(asset)
            } catch {
                Alerts.error("An error occurred while processing the video file.", error)
            }
            self?.refreshState()
        }
    }

    private func loadThumbnails(_ asset: AVAsset) {
        thumbnailTask?.cancel()
        timeline.thumbnails = []
        guard duration > 0 else { return }
        let count = 14
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 120)
        thumbnailTask = Task { @MainActor [weak self] in
            var images: [CGImage] = []
            for await result in generator.images(for: times) {
                if Task.isCancelled { return }
                if let image = try? result.image { images.append(image) }
            }
            self?.timeline.thumbnails = images
        }
    }

    private var trimRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: timeline.start, preferredTimescale: 600),
                    end: CMTime(seconds: timeline.end, preferredTimescale: 600))
    }

    private var hasAudio: Bool { audioTrackCount > 0 }
    private var hasPendingEdits: Bool { timeline.isTrimmed || (hasAudio && (!includeAudio || abs(volume - 1) > 0.001)) }

    private func options(quality: VideoQuality, shortSide: Int) -> VideoExportOptions {
        VideoExportOptions(timeRange: trimRange, includeAudio: hasAudio && includeAudio, volume: volume, quality: quality,
                           scale: RecordingMath.exportScale(source: naturalSize, shortSide: shortSide),
                           fileType: VideoExporter.fileType(for: media.url))
    }

    private func estimatedBytes(_ o: VideoExportOptions) -> Int64 {
        VideoExporter.estimatedSize(sourceBytes: fileBytes, sourceDuration: duration, options: o,
                                    pixelSize: naturalSize, fps: fps, audioTracks: audioTrackCount)
    }

    private func refreshState() {
        audioSwitch.state = hasAudio && includeAudio ? .on : .off
        audioSwitch.isEnabled = hasAudio
        volumeSlider.isEnabled = hasAudio && includeAudio
        volumeSlider.floatValue = volume
        volumeLabel.stringValue = "\(Int((volume * 100).rounded()))%"
        audioNote.stringValue = hasAudio ? (audioTrackCount > 1 && volume != 1 ? "Audio tracks are mixed into one on export." : "")
                                         : "This video has no audio."
        audioNote.isHidden = audioNote.stringValue.isEmpty
        player.isMuted = !includeAudio
        player.volume = volume
        trimLabel.stringValue = timeline.isTrimmed ? "Trimmed to \(EditorChrome.format(timeline.end - timeline.start))" : ""
        window?.isDocumentEdited = hasPendingEdits
        updateTime()
    }

    private func setBusy(_ busy: Bool) {
        titleButtons.forEach { $0.isEnabled = !busy }
        timeline.isEnabled = !busy
        timeline.needsDisplay = true
        if !busy { refreshState() }
    }

    // MARK: Playback

    private func playbackTick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if player.rate != 0, seconds >= timeline.end - 0.001 {
            player.pause()
            player.seek(to: CMTime(seconds: timeline.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            updatePlayButton()
        }
        timeline.playhead = min(max(seconds, 0), duration)
        updateTime()
    }

    private func updateTime() {
        timeLabel.stringValue = "\(EditorChrome.format(timeline.playhead)) / \(EditorChrome.format(duration))"
    }

    private func updatePlayButton() {
        let playing = player.rate != 0
        playButton.image = symbol(playing ? "pause.fill" : "play.fill", size: 15)
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
    }

    private func seek(to t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateTime()
    }

    private func togglePlay() {
        if player.rate == 0 {
            let now = player.currentTime().seconds
            if !(now >= timeline.start && now < timeline.end - 0.05) { seek(to: timeline.start) }
            player.play()
        } else {
            player.pause()
        }
        updatePlayButton()
    }

    private func markIn() { timeline.setTrim(start: min(timeline.playhead, timeline.end - 0.1), end: timeline.end) }
    private func markOut() { timeline.setTrim(start: timeline.start, end: max(timeline.playhead, timeline.start + 0.1)) }

    // MARK: Actions

    @objc private func playClicked() { togglePlay() }

    @objc private func audioChanged() {
        includeAudio = audioSwitch.state == .on
        refreshState()
    }

    @objc private func volumeChanged() {
        volume = volumeSlider.floatValue
        refreshState()
    }

    @objc private func exportClicked() {
        guard let window, duration > 0 else { return }
        player.pause()
        updatePlayButton()
        let sheet = ExportSheet(sourceSize: naturalSize, hasAudio: hasAudio, includeAudio: includeAudio) { [weak self] q, side, audio in
            guard let self else { return 0 }
            var o = self.options(quality: q, shortSide: side)
            o.includeAudio = audio && self.hasAudio
            return self.estimatedBytes(o)
        }
        sheet.onExport = { [weak self] q, side, audio, replace in
            guard let self else { return }
            self.includeAudio = audio
            if replace, !Alerts.confirm("Do you want to replace the existing video?", confirmTitle: "Replace") { return }
            var o = self.options(quality: q, shortSide: side)
            o.includeAudio = audio && self.hasAudio
            self.save(o, replacing: replace, then: nil)
        }
        sheet.onDismiss = { [weak self] in self?.exportSheet = nil }
        exportSheet = sheet
        if let sheetWindow = sheet.window { window.beginSheet(sheetWindow) }
    }

    /// Exports with `o`. Replacing writes over `media.url`; otherwise a new capture is added.
    private func save(_ o: VideoExportOptions, replacing: Bool, then: (() -> Void)?) {
        let source = media.url
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let dir = source.deletingLastPathComponent()
        let target = replacing ? AppPaths.temporary.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                               : AppPaths.uniqueURL(dir.appendingPathComponent("\(stem) (edited)").appendingPathExtension(ext))
        let progress = beginProgress("Exporting video…")
        exportTask = Task { @MainActor [weak self] in
            do {
                let size = try await VideoExporter.export(source: source, options: o, to: target) { p in
                    DispatchQueue.main.async { MainActor.assumeIsolated { progress.update(p) } }
                }
                guard let self else { try? FileManager.default.removeItem(at: target); return }
                let scale = max(1, self.media.scale * CGFloat(o.scale))
                if replacing {
                    self.player.replaceCurrentItem(with: nil)
                    _ = try FileManager.default.replaceItemAt(source, withItemAt: target)
                    self.media.pixelSize = size
                    self.media.scale = scale
                    self.media.notifyChanged()
                    self.includeAudio = true
                    self.volume = 1
                    self.loadMedia()
                } else {
                    let new = CapturedMedia(url: target, kind: .video, mode: self.media.mode, pixelSize: size, scale: scale)
                    MediaPipeline.ingest(new, actions: [.showQuickAccess])
                }
                self.endProgress()
                Sound.play(.exportDone)
                HUD.show(replacing ? "Video saved" : "Saved as new video")
                then?()
            } catch {
                try? FileManager.default.removeItem(at: target)
                self?.endProgress()
                if replacing, self?.player.currentItem == nil { self?.loadMedia() }
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
        let width = naturalSize.width
        player.pause()
        updatePlayButton()
        let progress = beginProgress("Creating GIF…")
        exportTask = Task { @MainActor [weak self] in
            do {
                let size = try await GIFEncoder.convert(video: source, to: output, timeRange: range, fps: Defaults[.gifFPS],
                                                        maxWidth: Defaults[.gifMaxWidth]) { p in
                    DispatchQueue.main.async { MainActor.assumeIsolated { progress.update(p) } }
                }
                let gifScale = max(1, scale * size.width / max(1, width))
                let gif = CapturedMedia(url: output, kind: .gif, mode: .gifRecording, pixelSize: size, scale: gifScale)
                MediaPipeline.ingest(gif, actions: [.showQuickAccess])
                self?.endProgress()
            } catch {
                try? FileManager.default.removeItem(at: output)
                self?.endProgress()
                if case GIFError.cancelled = error { return }
                Alerts.error("An error occurred while processing the video file.", error)
            }
        }
    }

    private func beginProgress(_ title: String) -> ExportProgressSheet {
        setBusy(true)
        let sheet = ExportProgressSheet(title: title) { [weak self] in self?.exportTask?.cancel() }
        progressSheet = sheet
        if let window, let sheetWindow = sheet.window { window.beginSheet(sheetWindow) }
        return sheet
    }

    private func endProgress() {
        if let sheetWindow = progressSheet?.window { window?.endSheet(sheetWindow) }
        progressSheet = nil
        exportTask = nil
        setBusy(false)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if exportTask != nil { NSSound.beep(); return false }
        guard hasPendingEdits else { return true }
        let a = NSAlert()
        a.messageText = "Do you want to save the changes to this video?"
        a.informativeText = "If you don't save, your edits will be lost."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let discard = a.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        switch a.runModal() {
        case .alertFirstButtonReturn:
            save(options(quality: Defaults[.rkExportQuality], shortSide: Defaults[.rkExportShortSide]), replacing: true) { [weak self] in
                self?.window?.close()
            }
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        exportTask?.cancel()
        thumbnailTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        onClose?()
    }
}

// MARK: - Export sheet

/// Resolution, Quality, Audio, Estimated file size; Cancel / Export.
@MainActor
private final class ExportSheet: NSWindowController {
    var onExport: ((_ quality: VideoQuality, _ shortSide: Int, _ audio: Bool, _ replace: Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let estimate: (VideoQuality, Int, Bool) -> Int64
    private let resolutionPopup = NSPopUpButton()
    private let qualitySlider = NSSlider()
    private let qualityLabel = NSTextField(labelWithString: "")
    private let audioSwitch = NSSwitch()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let replaceCheckbox = NSButton(checkboxWithTitle: "Replace the original video", target: nil, action: nil)

    init(sourceSize: CGSize, hasAudio: Bool, includeAudio: Bool, estimate: @escaping (VideoQuality, Int, Bool) -> Int64) {
        self.estimate = estimate
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)

        let saved = Defaults[.rkExportShortSide]
        for option in RecordingMath.exportOptions(for: sourceSize) {
            let title = option.shortSide == 0 ? "Original (\(option.size.width) × \(option.size.height))"
                                              : "\(option.title) (\(option.size.width) × \(option.size.height))"
            resolutionPopup.addItem(withTitle: title)
            resolutionPopup.lastItem?.tag = option.shortSide
            if option.shortSide == saved { resolutionPopup.select(resolutionPopup.lastItem) }
        }
        resolutionPopup.target = self
        resolutionPopup.action = #selector(changed)

        let qualities = VideoQuality.allCases
        qualitySlider.minValue = 0
        qualitySlider.maxValue = Double(qualities.count - 1)
        qualitySlider.numberOfTickMarks = qualities.count
        qualitySlider.allowsTickMarkValuesOnly = true
        qualitySlider.integerValue = qualities.firstIndex(of: Defaults[.rkExportQuality]) ?? qualities.count - 1
        qualitySlider.target = self
        qualitySlider.action = #selector(changed)
        qualityLabel.font = .systemFont(ofSize: 12)
        qualityLabel.textColor = .secondaryLabelColor
        qualityLabel.alignment = .right
        qualityLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        audioSwitch.state = hasAudio && includeAudio ? .on : .off
        audioSwitch.isEnabled = hasAudio
        audioSwitch.target = self
        audioSwitch.action = #selector(changed)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        sizeLabel.alignment = .right

        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let r = NSStackView(views: [label] + views)
            r.spacing = 8
            return r
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let export = NSButton(title: "Export", target: self, action: #selector(exportClicked))
        export.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, export])
        let rows = [row("Resolution", [resolutionPopup]), row("Quality", [qualitySlider, qualityLabel]),
                    row("Audio", [audioSwitch, NSView()]), row("Estimated file size", [NSView(), sizeLabel])]
        let stack = NSStackView(views: rows + [replaceCheckbox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(20, after: replaceCheckbox)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        for v in rows + [buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        panel.contentView = stack
        changed()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var quality: VideoQuality { VideoQuality.allCases[max(0, min(VideoQuality.allCases.count - 1, qualitySlider.integerValue))] }
    private var shortSide: Int { resolutionPopup.selectedItem?.tag ?? 0 }

    @objc private func changed() {
        qualityLabel.stringValue = quality.displayName
        sizeLabel.stringValue = "~" + RecordingMath.formattedByteCount(estimate(quality, shortSide, audioSwitch.state == .on))
    }

    private func dismiss() {
        if let window { window.sheetParent?.endSheet(window) }
        // Released on the next turn so this controller outlives the action that dismissed it.
        let done = onDismiss
        DispatchQueue.main.async { done?() }
    }

    @objc private func cancelClicked() { dismiss() }

    @objc private func exportClicked() {
        Defaults[.rkExportQuality] = quality
        Defaults[.rkExportShortSide] = shortSide
        let (q, side, audio, replace) = (quality, shortSide, audioSwitch.state == .on, replaceCheckbox.state == .on)
        let export = onExport
        dismiss()
        export?(q, side, audio, replace)
    }
}

// MARK: - Progress sheet

/// "Exporting video…" with a thin bar, time remaining, percentage and Cancel Export.
@MainActor
final class ExportProgressSheet: NSWindowController {
    private let bar = NSProgressIndicator()
    private let remainingLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let onCancel: () -> Void
    private let started = Date()

    init(title: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        for l in [remainingLabel, percentLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.textColor = .secondaryLabelColor
        }
        let info = NSStackView(views: [remainingLabel, NSView(), percentLabel])
        let cancel = NSButton(title: "Cancel Export", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [titleLabel, bar, info, cancel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: info)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 16, right: 22)
        for v in [bar, info] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true }
        panel.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ p: Double) {
        let p = max(0, min(1, p))
        bar.doubleValue = p
        percentLabel.stringValue = "\(Int((p * 100).rounded()))%"
        let elapsed = Date().timeIntervalSince(started)
        if p > 0.02, elapsed > 1 {
            let remaining = elapsed / p * (1 - p)
            remainingLabel.stringValue = "~\(Int(remaining.rounded(.up)))s remaining"
        }
    }

    @objc private func cancelClicked() { onCancel() }
}
