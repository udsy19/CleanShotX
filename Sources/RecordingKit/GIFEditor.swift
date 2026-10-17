import AppKit
import ShotcraftCore

/// GIF player with frame-based trimming (the GIFTrimmer equivalent), re-encoded with ImageIO.
@MainActor
final class GIFEditorWindowController: NSWindowController, NSWindowDelegate, MediaEditor {
    let media: CapturedMedia
    var onClose: (() -> Void)?

    private var frames: GIFEncoder.Frames?
    private let imageView = NSImageView()
    private let startSlider = NSSlider()
    private let endSlider = NSSlider()
    private let startLabel = NSTextField(labelWithString: "")
    private let endLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private var saveButtons: [NSButton] = []
    private var playTimer: Timer?
    private var currentFrame = 0

    init(media: CapturedMedia) {
        self.media = media
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 380)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.onSpace = { [weak self] in self?.togglePlay() }
        buildUI()
        load()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var range: ClosedRange<Int> {
        let a = startSlider.integerValue, b = endSlider.integerValue
        return min(a, b)...max(a, b)
    }

    private var isTrimmed: Bool {
        guard let frames else { return false }
        return range != 0...(frames.images.count - 1)
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor

        for (slider, sel) in [(startSlider, #selector(startChanged)), (endSlider, #selector(endChanged))] {
            slider.target = self
            slider.action = sel
            slider.isContinuous = true
            slider.minValue = 0
        }
        startLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        endLabel.font = startLabel.font
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        playButton.bezelStyle = .regularSquare
        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(playClicked)
        playButton.toolTip = "Play / Pause (Space)"

        let startRow = NSStackView(views: [NSTextField(labelWithString: "Start"), startSlider, startLabel])
        let endRow = NSStackView(views: [NSTextField(labelWithString: "End"), endSlider, endLabel])
        for row in [startRow, endRow] { row.spacing = 8 }
        startRow.views[0].widthAnchor.constraint(equalToConstant: 36).isActive = true
        endRow.views[0].widthAnchor.constraint(equalToConstant: 36).isActive = true
        startLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        endLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let saveNew = editorButton("Save as New GIF", symbolName: nil, target: self, action: #selector(saveAsNewClicked))
        let save = editorButton("Save", symbolName: nil, target: self, action: #selector(saveClicked))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        saveButtons = [saveNew, save]
        let buttons = NSStackView(views: [playButton, infoLabel, NSView(), saveNew, save])

        let controls = NSStackView(views: [startRow, endRow, buttons])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        controls.translatesAutoresizingMaskIntoConstraints = false
        for v in [startRow, endRow, buttons] { v.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -28).isActive = true }

        content.addSubview(imageView)
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
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
        let last = Double(f.images.count - 1)
        for s in [startSlider, endSlider] {
            s.maxValue = max(1, last)
            s.numberOfTickMarks = f.images.count <= 60 ? f.images.count : 0
            s.allowsTickMarkValuesOnly = f.images.count <= 60
            s.isEnabled = f.images.count > 1
        }
        startSlider.integerValue = 0
        endSlider.integerValue = f.images.count - 1
        show(frame: 0)
        refresh()
        play()
    }

    private func time(at index: Int) -> Double {
        guard let frames else { return 0 }
        return frames.delays.prefix(index).reduce(0, +)
    }

    private func refresh() {
        guard let frames else { return }
        let r = range
        startLabel.stringValue = "Frame \(r.lowerBound + 1) · \(String(format: "%.2fs", time(at: r.lowerBound)))"
        endLabel.stringValue = "Frame \(r.upperBound + 1) · \(String(format: "%.2fs", time(at: r.upperBound + 1)))"
        let duration = frames.delays[r].reduce(0, +)
        infoLabel.stringValue = "\(r.count) of \(frames.images.count) frames · \(String(format: "%.1fs", duration))"
        window?.isDocumentEdited = isTrimmed
        saveButtons.forEach { $0.isEnabled = isTrimmed }
    }

    private func show(frame i: Int) {
        guard let frames, frames.images.indices.contains(i) else { return }
        currentFrame = i
        imageView.image = ImageTools.nsImage(frames.images[i], scale: max(1, media.scale))
    }

    // MARK: Playback (timer-driven so it honours the trimmed range)

    private func play() {
        guard let frames, frames.images.count > 1, playTimer == nil else { return }
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
        playButton.image = symbol(playTimer == nil ? "play.fill" : "pause.fill", size: 15)
    }

    // MARK: Actions

    @objc private func playClicked() { togglePlay() }

    @objc private func startChanged() {
        stop()
        if startSlider.integerValue > endSlider.integerValue { endSlider.integerValue = startSlider.integerValue }
        show(frame: startSlider.integerValue)
        refresh()
    }

    @objc private func endChanged() {
        stop()
        if endSlider.integerValue < startSlider.integerValue { startSlider.integerValue = endSlider.integerValue }
        show(frame: endSlider.integerValue)
        refresh()
    }

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
