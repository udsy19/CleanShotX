import AppKit
import ShotcraftCore

/// GIF player with a trim timeline (the GIFTrimmer equivalent), re-encoded frame by frame.
@MainActor
final class GIFEditorWindowController: NSWindowController, NSWindowDelegate, MediaEditor {
    let media: CapturedMedia
    var onClose: (() -> Void)?

    private var frames: GIFEncoder.Frames?
    private let imageView = NSImageView()
    private let timeline = TimelineView()
    private var playButton: NSButton!
    private let timeLabel = EditorChrome.timeLabel()
    private let infoLabel = EditorChrome.timeLabel()
    private var saveButtons: [NSButton] = []
    private var playTimer: Timer?
    private var currentFrame = 0
    /// Start time of each frame.
    private var frameStarts: [Double] = []

    init(media: CapturedMedia) {
        self.media = media
        let window = EditorChrome.makeWindow(title: media.url.lastPathComponent, url: media.url,
                                             size: NSSize(width: 820, height: 600), minSize: NSSize(width: 560, height: 400))
        super.init(window: window)
        window.delegate = self
        window.onSpace = { [weak self] in self?.togglePlay() }
        window.onMarkIn = { [weak self] in self?.markIn() }
        window.onMarkOut = { [weak self] in self?.markOut() }
        buildUI()
        load()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Frames inside the trimmed time range.
    private var range: ClosedRange<Int> {
        guard let frames else { return 0...0 }
        let first = RecordingMath.frameIndex(at: timeline.start + 1e-6, delays: frames.delays)
        let last = max(first, RecordingMath.frameIndex(at: max(0, timeline.end - 1e-6), delays: frames.delays))
        return first...last
    }

    private var isTrimmed: Bool {
        guard let frames else { return false }
        return range != 0...(frames.count - 1)
    }

    // MARK: UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor

        playButton = EditorChrome.playButton(target: self, action: #selector(playClicked))
        infoLabel.alignment = .right
        let bottom = EditorChrome.bottomBar(transport: [playButton, timeLabel, NSView(), infoLabel], timeline: timeline)
        timeline.onScrub = { [weak self] t in self?.scrub(to: t) }
        timeline.onTrimChange = { [weak self] _, _ in self?.refresh() }

        content.addSubview(imageView)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let saveNew = EditorChrome.button("Save as New GIF", symbolName: nil, target: self, action: #selector(saveAsNewClicked))
        let save = EditorChrome.button("Save", symbolName: nil, target: self, action: #selector(saveClicked))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        save.bezelColor = .controlAccentColor
        saveButtons = [saveNew, save]
        EditorChrome.addTitlebarButtons(saveButtons, to: window)
        updatePlayButton()
    }

    private func load() {
        window?.title = media.url.lastPathComponent
        window?.representedURL = media.url
        stop()
        guard let f = GIFEncoder.loadFrames(media.url) else {
            Alerts.error("An error occurred while processing the video file.")
            return
        }
        frames = f
        var t = 0.0
        frameStarts = f.delays.map { d in defer { t += d }; return t }
        timeline.duration = f.duration
        timeline.isEnabled = f.count > 1
        let step = max(1, f.count / 14)
        timeline.thumbnails = stride(from: 0, to: f.count, by: step).compactMap { f.thumbnail(at: $0, maxPixelSize: 160) }
        show(frame: 0)
        refresh()
        play()
    }

    private func refresh() {
        guard let frames else { return }
        let r = range
        let duration = frames.delays[r].reduce(0, +)
        infoLabel.stringValue = "\(r.count) of \(frames.count) frames · \(String(format: "%.1fs", duration))"
        window?.isDocumentEdited = isTrimmed
        saveButtons.forEach { $0.isEnabled = isTrimmed }
    }

    private func show(frame i: Int) {
        guard let frames, let image = frames.image(at: i) else { return }
        currentFrame = i
        imageView.image = ImageTools.nsImage(image, scale: max(1, media.scale))
        timeline.playhead = frameStarts[i]
        timeLabel.stringValue = "\(EditorChrome.format(frameStarts[i])) / \(EditorChrome.format(frames.duration))"
    }

    private func scrub(to t: Double) {
        guard let frames else { return }
        stop()
        show(frame: RecordingMath.frameIndex(at: t, delays: frames.delays))
        timeline.playhead = t
    }

    private func markIn() { timeline.setTrim(start: min(timeline.playhead, timeline.end - 0.1), end: timeline.end) }
    private func markOut() { timeline.setTrim(start: timeline.start, end: max(timeline.playhead, timeline.start + 0.1)) }

    // MARK: Playback (timer-driven so it honours the trimmed range)

    private func play() {
        guard let frames, frames.count > 1, playTimer == nil else { return }
        if !range.contains(currentFrame) { show(frame: range.lowerBound) }
        scheduleNext(after: frames.delays[currentFrame])
        updatePlayButton()
    }

    private func scheduleNext(after delay: Double) {
        playTimer = Timer.scheduledTimer(withTimeInterval: max(0.02, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let frames = self.frames else { return }
                let r = self.range
                let next = self.currentFrame + 1 > r.upperBound ? r.lowerBound : self.currentFrame + 1
                self.show(frame: next)
                self.scheduleNext(after: frames.delays[next])
            }
        }
    }

    private func stop() {
        playTimer?.invalidate()
        playTimer = nil
        updatePlayButton()
    }

    private func togglePlay() { playTimer == nil ? play() : stop() }

    private func updatePlayButton() {
        playButton?.image = symbol(playTimer == nil ? "play.fill" : "pause.fill", size: 15)
        playButton?.setAccessibilityLabel(playTimer == nil ? "Play" : "Pause")
    }

    // MARK: Actions

    @objc private func playClicked() { togglePlay() }

    @objc private func saveClicked() {
        guard Alerts.confirm("Do you want to replace the existing GIF?", confirmTitle: "Replace") else { return }
        _ = write(replacing: true)
    }

    @objc private func saveAsNewClicked() { _ = write(replacing: false) }

    private func write(replacing: Bool) -> Bool {
        guard let frames else { return false }
        let source = media.url
        let target = replacing
            ? AppPaths.temporary.appendingPathComponent(UUID().uuidString).appendingPathExtension("gif")
            : AppPaths.uniqueURL(source.deletingLastPathComponent()
                .appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) (edited)").appendingPathExtension("gif"))
        do {
            try GIFEncoder.write(frames, range: range, to: target)
            if replacing {
                _ = try FileManager.default.replaceItemAt(source, withItemAt: target)
                media.notifyChanged()
                load()
            } else {
                let new = CapturedMedia(url: target, kind: .gif, mode: media.mode, pixelSize: media.pixelSize, scale: media.scale)
                MediaPipeline.ingest(new, actions: [.showQuickAccess])
            }
            HUD.show(replacing ? "GIF saved" : "Saved as new GIF")
            return true
        } catch {
            try? FileManager.default.removeItem(at: target)
            Alerts.error("An error occurred while processing the video file.", error)
            return false
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isTrimmed else { return true }
        let a = NSAlert()
        a.messageText = "Do you want to trim the GIF?"
        a.informativeText = "If you don't save, the GIF will not be trimmed."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let discard = a.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        switch a.runModal() {
        case .alertFirstButtonReturn: return write(replacing: true)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        stop()
        onClose?()
    }
}
