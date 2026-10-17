import AppKit
import AVFoundation
import ShotcraftCore

/// Container view of a card: forwards mouse/scroll/hover events to the card.
final class QuickAccessCardView: NSView {
    weak var card: QuickAccessCard?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { card?.setHovered(true) }
    override func mouseExited(with event: NSEvent) { card?.setHovered(false) }
    override func mouseDown(with event: NSEvent) { card?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { card?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { card?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { card?.showContextMenu(event, in: self) }
    override func scrollWheel(with event: NSEvent) { card?.scroll(event) }
}

/// One Quick Access Overlay card: a non-activating panel showing a capture with hover actions.
@MainActor
final class QuickAccessCard: NSObject, NSDraggingSource {
    let media: CapturedMedia
    let panel: OverlayPanel
    private let root = QuickAccessCardView()
    private let chrome = NSVisualEffectView()
    private let thumb = PassthroughImageView()
    private let hoverOverlay = PassthroughView()
    private let durationBadge = NSTextField(labelWithString: "")
    private let progressOverlay = NSVisualEffectView()
    private let progressRing = CircularProgressView()
    private let progressTick = PassthroughImageView()
    private let progressLabel = NSTextField(labelWithString: "")
    private var uploadButton: OverlayButton?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: NSObjectProtocol?

    private(set) var isHovered = false
    private(set) var isUploading = false
    private var isDragging = false
    private var isClosing = false
    private var mouseDownPoint: NSPoint?
    private var swipeOffset: CGFloat = 0
    private var autoCloseWork: DispatchWorkItem?

    /// Frame assigned by the last layout pass (nil = hidden because the stack is full).
    var targetFrame: CGRect?

    init(media: CapturedMedia) {
        self.media = media
        panel = OverlayWindow.makePanel(NSRect(x: 0, y: 0, width: 200, height: 125), level: OverlayWindow.quickAccessLevel)
        super.init()
        root.card = self
        buildUI()
        panel.contentView = root
        reloadThumbnail()
        scheduleAutoClose()
    }

    // MARK: UI

    private func buildUI() {
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true

        chrome.material = .hudWindow
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.maskImage = .roundedMask(radius: 12)
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.imageAlignment = .alignCenter
        thumb.animates = true            // GIFs play
        thumb.wantsLayer = true
        thumb.autoresizingMask = [.width, .height]
        root.addSubview(thumb)

        durationBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        durationBadge.textColor = .white
        durationBadge.wantsLayer = true
        durationBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        durationBadge.layer?.cornerRadius = 4
        durationBadge.isHidden = !media.isVideoLike
        durationBadge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(durationBadge)

        buildHoverOverlay()
        buildProgressOverlay()

        NSLayoutConstraint.activate([
            durationBadge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            durationBadge.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Quick Access: \(media.url.lastPathComponent)")
    }

    private func buildHoverOverlay() {
        hoverOverlay.wantsLayer = true
        hoverOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        hoverOverlay.autoresizingMask = [.width, .height]
        hoverOverlay.alphaValue = 0
        root.addSubview(hoverOverlay)

        let copy = OverlayButton(.pill("Copy"), tooltip: "Copy to clipboard (⌘C)") { [weak self] in self?.copy() }
        let save = OverlayButton(.pill("Save"), tooltip: "Save (⌘S)") { [weak self] in self?.save() }
        let center = NSStackView(views: [copy, save])
        center.orientation = .vertical
        center.spacing = 8
        center.translatesAutoresizingMaskIntoConstraints = false
        hoverOverlay.addSubview(center)

        let close = OverlayButton(.icon("xmark"), tooltip: "Close (Esc)", diameter: 22) { [weak self] in self?.close(recordForRestore: true) }
        let edit = OverlayButton(.icon(media.isImage ? "pencil" : "scissors"), tooltip: MediaActions.editTitle(for: media)) { [weak self] in
            self?.edit()
        }
        let quickLook = OverlayButton(.icon("eye"), tooltip: "Open Quick Look (Space)") { [weak self] in self?.quickLook() }
        var topRight: [NSView] = [edit]
        if media.isImage {
            topRight.insert(OverlayButton(.icon("pin"), tooltip: "Pin to the screen (⌘P)") { [weak self] in self?.pin() }, at: 0)
        }
        let trStack = NSStackView(views: topRight)
        trStack.spacing = 6
        trStack.translatesAutoresizingMaskIntoConstraints = false
        [close, quickLook, trStack].forEach(hoverOverlay.addSubview)

        let upload = OverlayButton(.icon("icloud.and.arrow.up"), tooltip: "Upload (⌘U)") { [weak self] in self?.upload() }
        hoverOverlay.addSubview(upload)
        uploadButton = upload
        updateUploadButtonVisibility()

        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: hoverOverlay.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: hoverOverlay.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: hoverOverlay.leadingAnchor, constant: 8),
            close.topAnchor.constraint(equalTo: hoverOverlay.topAnchor, constant: 8),
            trStack.trailingAnchor.constraint(equalTo: hoverOverlay.trailingAnchor, constant: -8),
            trStack.topAnchor.constraint(equalTo: hoverOverlay.topAnchor, constant: 8),
            quickLook.leadingAnchor.constraint(equalTo: hoverOverlay.leadingAnchor, constant: 8),
            quickLook.bottomAnchor.constraint(equalTo: hoverOverlay.bottomAnchor, constant: -8),
            upload.trailingAnchor.constraint(equalTo: hoverOverlay.trailingAnchor, constant: -8),
            upload.bottomAnchor.constraint(equalTo: hoverOverlay.bottomAnchor, constant: -8),
        ])
    }

    private func buildProgressOverlay() {
        progressOverlay.material = .hudWindow
        progressOverlay.blendingMode = .withinWindow
        progressOverlay.state = .active
        progressOverlay.appearance = NSAppearance(named: .vibrantDark)
        progressOverlay.autoresizingMask = [.width, .height]
        progressOverlay.isHidden = true
        root.addSubview(progressOverlay)

        progressRing.translatesAutoresizingMaskIntoConstraints = false
        progressTick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .semibold))
        progressTick.contentTintColor = .white
        progressTick.isHidden = true
        progressTick.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        progressLabel.textColor = .white
        progressLabel.alignment = .center
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        [progressRing, progressTick, progressLabel].forEach(progressOverlay.addSubview)
        NSLayoutConstraint.activate([
            progressRing.centerXAnchor.constraint(equalTo: progressOverlay.centerXAnchor),
            progressRing.centerYAnchor.constraint(equalTo: progressOverlay.centerYAnchor, constant: -10),
            progressRing.widthAnchor.constraint(equalToConstant: 36),
            progressRing.heightAnchor.constraint(equalToConstant: 36),
            progressTick.centerXAnchor.constraint(equalTo: progressRing.centerXAnchor),
            progressTick.centerYAnchor.constraint(equalTo: progressRing.centerYAnchor),
            progressLabel.topAnchor.constraint(equalTo: progressRing.bottomAnchor, constant: 8),
            progressLabel.centerXAnchor.constraint(equalTo: progressOverlay.centerXAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: progressOverlay.leadingAnchor, constant: 6),
        ])
    }

    func updateUploadButtonVisibility() {
        uploadButton?.isHidden = !Defaults[.quickAccessShowUploadButton] || isUploading
    }

    /// Reloads the thumbnail and video duration (after edits, saves or renames).
    func reloadThumbnail() {
        root.setAccessibilityLabel("Quick Access: \(media.url.lastPathComponent)")
        if media.kind == .gif, let animated = NSImage(contentsOf: media.url) {
            thumb.image = animated
        } else {
            let px = QuickAccessLayout.cardSize(for: media.pixelSize, scale: Defaults[.quickAccessSize]).width
                * 2 * (NSScreen.active.backingScaleFactor)
            let url = media.url
            Thumbnailer.thumbnail(for: url, kind: media.kind, maxPixel: px) { [weak self] img in
                guard let self, self.media.url == url else { return }
                self.thumb.image = img
            }
        }
        if media.isVideoLike && media.kind != .studioProject {
            let asset = AVURLAsset(url: media.url)
            Task { @MainActor [weak self] in
                guard let d = try? await asset.load(.duration) else { return }
                self?.durationBadge.stringValue = " \(OverlayFormat.duration(d.seconds)) "
            }
        }
    }

    // MARK: Hover

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered, !isClosing else { return }
        isHovered = hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hoverOverlay.animator().alphaValue = hovered && !isUploading ? 1 : 0
            durationBadge.animator().alphaValue = hovered ? 0 : 1
        }
        if hovered {
            autoCloseWork?.cancel()
            HoverHotkeys.shared.activate(owner: self, hotkeyBindings())
            startHoverPlayback()
        } else {
            HoverHotkeys.shared.deactivate(owner: self)
            stopHoverPlayback()
            scheduleAutoClose()
        }
    }

    private func hotkeyBindings() -> [HoverHotkeys.Binding] {
        [
            .init(Keys.c, .command) { [weak self] in self?.copy() },
            .init(Keys.s, .command) { [weak self] in self?.save() },
            .init(Keys.a, .command) { [weak self] in self?.edit() },
            .init(Keys.p, .command) { [weak self] in self?.pin() },
            .init(Keys.u, .command) { [weak self] in self?.upload() },
            .init(Keys.w, .command) { [weak self] in self?.close(recordForRestore: true) },
            .init(Keys.escape) { [weak self] in self?.close(recordForRestore: true) },
            .init(Keys.space) { [weak self] in self?.quickLook() },
        ]
    }

    private func startHoverPlayback() {
        guard media.kind == .video, player == nil else { return }
        let p = AVPlayer(url: media.url)
        p.isMuted = true
        p.actionAtItemEnd = .none
        let layer = AVPlayerLayer(player: p)
        layer.videoGravity = .resizeAspect
        layer.frame = thumb.bounds
        thumb.layer?.addSublayer(layer)
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem,
                                                              queue: .main) { [weak p] _ in p?.seek(to: .zero); p?.play() }
        player = p
        playerLayer = layer
        p.play()
    }

    private func stopHoverPlayback() {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        loopObserver = nil
        player = nil
        playerLayer = nil
    }

    // MARK: Auto close

    func scheduleAutoClose() {
        autoCloseWork?.cancel()
        guard Defaults[.quickAccessAutoClose], !isHovered, !isUploading, !isClosing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovered, !self.isUploading, !self.isDragging else { return }
            if let action = Defaults[.quickAccessAutoCloseAction] { MediaPipeline.perform(action, on: self.media) }
            self.close(recordForRestore: true)
        }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(max(1, Defaults[.quickAccessAutoCloseSeconds])), execute: work)
    }

    // MARK: Actions

    func copy() {
        MediaActions.copy(media)
        close(recordForRestore: true)
    }

    func save(forceAsk: Bool = false) {
        if MediaActions.save(media, forceAsk: forceAsk) { close(recordForRestore: true) }
    }

    func edit() {
        MediaActions.edit(media)
    }

    func pin() {
        guard media.isImage else { NSSound.beep(); return }
        MediaActions.pin(media)
        close(recordForRestore: true)
    }

    func quickLook() {
        QuickLookController.shared.toggle(media.url, pointSize: media.pointSize)
    }

    func upload() {
        guard !isUploading else { return }
        guard MediaActions.canUpload else { MediaActions.upload(media, progress: nil, completion: nil); return }
        isUploading = true
        autoCloseWork?.cancel()
        updateUploadButtonVisibility()
        hoverOverlay.alphaValue = 0
        progressRing.progress = 0
        progressRing.isHidden = false
        progressTick.isHidden = true
        progressLabel.stringValue = "Uploading…"
        progressOverlay.isHidden = false
        MediaActions.upload(media, progress: { [weak self] p in
            self?.progressRing.progress = p
        }, completion: { [weak self] result in
            self?.uploadFinished(result)
        })
    }

    private func uploadFinished(_ result: Result<URL, Error>) {
        isUploading = false
        updateUploadButtonVisibility()
        switch result {
        case .success:
            progressRing.isHidden = true
            progressTick.isHidden = false
            progressLabel.stringValue = "Link has been copied"
            Sound.play(.uploadDone)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, !self.isClosing else { return }
                if Defaults[.quickAccessCloseAfterUploading] {
                    self.close(recordForRestore: true)
                } else {
                    self.progressOverlay.isHidden = true
                    if self.isHovered { self.hoverOverlay.alphaValue = 1 }
                    self.scheduleAutoClose()
                }
            }
        case .failure(let error):
            progressOverlay.isHidden = true
            if isHovered { hoverOverlay.alphaValue = 1 }
            if case UploadError.notConfigured = error {} else { Alerts.error("Upload failed.", error) }
            scheduleAutoClose()
        }
    }

    func close(recordForRestore: Bool) {
        guard !isClosing else { return }
        isClosing = true
        autoCloseWork?.cancel()
        HoverHotkeys.shared.deactivate(owner: self)
        stopHoverPlayback()
        if QuickLookController.shared.currentURL == media.url { QuickLookController.shared.close() }
        QuickAccessController.shared.cardDidClose(self, recordForRestore: recordForRestore)
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        if event.clickCount == 2 { edit() }
    }

    func mouseDragged(_ event: NSEvent) {
        guard !isDragging, !isUploading, let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        beginFileDrag(event)
    }

    func mouseUp(_ event: NSEvent) {
        mouseDownPoint = nil
    }

    private func beginFileDrag(_ event: NSEvent) {
        guard FileManager.default.fileExists(atPath: media.url.path) else { NSSound.beep(); return }
        let item = NSDraggingItem(pasteboardWriter: media.url as NSURL)
        let image = thumb.image ?? NSWorkspace.shared.icon(forFile: media.url.path)
        let size = root.bounds.size
        item.setDraggingFrame(NSRect(origin: .zero, size: size), contents: image)
        isDragging = true
        autoCloseWork?.cancel()
        let session = root.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 0.35 }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { dragEnded(at: screenPoint, operation: operation) }
    }

    private func dragEnded(at point: NSPoint, operation: NSDragOperation) {
        isDragging = false
        panel.alphaValue = 1
        let screen = panel.screen ?? NSScreen.active
        if operation != [] {
            if Defaults[.quickAccessCloseAfterDragging] { close(recordForRestore: true); return }
        } else if QuickAccessLayout.isAtEdge(point, of: screen.frame, side: Defaults[.quickAccessSide]) {
            close(recordForRestore: true); return   // flung to the screen edge → dismiss
        }
        scheduleAutoClose()
    }

    /// Horizontal two-finger swipe toward the screen edge dismisses the card.
    func scroll(_ event: NSEvent) {
        guard !isClosing, let target = targetFrame, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) || swipeOffset != 0 else { return }
        let side = Defaults[.quickAccessSide]
        let fingerDX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        switch event.phase {
        case .began, .changed:
            swipeOffset += fingerDX
            // Only toward the edge (a little rubber band inward).
            swipeOffset = side == .left ? min(swipeOffset, 12) : max(swipeOffset, -12)
            panel.setFrameOrigin(NSPoint(x: target.minX + swipeOffset, y: target.minY))
        case .ended, .cancelled:
            let dismiss = abs(swipeOffset) > target.width * 0.35 && (side == .left ? swipeOffset < 0 : swipeOffset > 0)
            swipeOffset = 0
            if dismiss { close(recordForRestore: true) } else {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().setFrame(target, display: true) }
            }
        default:
            break
        }
    }

    // MARK: Context menu

    func showContextMenu(_ event: NSEvent, in view: NSView) {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak self] in if let self { MediaActions.open(self.media) } })
        m.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { [weak self] in if let self { MediaActions.showInFinder(self.media) } })
        m.addItem(ClosureMenuItem("Rename…", symbol: "pencil.line") { [weak self] in if let self { MediaActions.rename(self.media) } })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Copy", key: "c", symbol: "doc.on.doc") { [weak self] in self?.copy() })
        m.addItem(ClosureMenuItem("Save As…", key: "s", modifiers: [.command, .shift], symbol: "square.and.arrow.down") { [weak self] in
            self?.save(forceAsk: true)
        })
        m.addItem(ClosureMenuItem(media.isImage ? "Annotate" : "Open Video Editor", key: "a", symbol: media.isImage ? "pencil" : "scissors") { [weak self] in
            self?.edit()
        })
        let upload = ClosureMenuItem("Upload", key: "u", symbol: "icloud.and.arrow.up") { [weak self] in self?.upload() }
        upload.isEnabled = !isUploading
        m.addItem(upload)
        if media.isImage { m.addItem(ClosureMenuItem("Pin to the Screen", key: "p", symbol: "pin") { [weak self] in self?.pin() }) }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Move to Trash", symbol: "trash") { [weak self] in if let self { MediaActions.moveToTrash(self.media) } })
        m.addItem(ClosureMenuItem("Close", key: "w", symbol: "xmark") { [weak self] in self?.close(recordForRestore: true) })
        NSMenu.popUpContextMenu(m, with: event, for: view)
    }
}
