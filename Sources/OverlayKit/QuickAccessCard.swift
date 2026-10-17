import AppKit
import AVFoundation
import SuperScreenshotCore

/// Container view of a card: forwards mouse/scroll/hover events to the card.
final class QuickAccessCardView: NSView {
    weak var card: QuickAccessCard?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTracking(on: self, existing: &hoverArea)
    }

    override func mouseEntered(with event: NSEvent) { card?.setHovered(true) }
    override func mouseExited(with event: NSEvent) { card?.setHovered(false) }
    override func mouseDown(with event: NSEvent) { card?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { card?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { card?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { card?.showContextMenu(event, in: self) }
    override func scrollWheel(with event: NSEvent) { card?.scroll(event) }
}

/// One Quick Access Overlay card (ui-reference §4): a non-activating panel whose thumbnail fills a rounded card.
/// Hover dims + frosts it and reveals Copy / Save pills in the centre and four corner buttons.
@MainActor
final class QuickAccessCard: NSObject, NSDraggingSource {
    let media: CapturedMedia
    let panel: OverlayPanel
    private let root = QuickAccessCardView()
    private let chrome = NSVisualEffectView()
    private let thumb = ThumbnailView()
    private let hoverOverlay = PassthroughView()
    private let frost = PassthroughEffectView()
    private let durationLabel = NSTextField(labelWithString: "")
    private var secondaryPill: OverlayButton!
    private var uploadButton: OverlayButton!
    private var cornerButtons: [OverlayButton] = []
    private let progressOverlay = PassthroughEffectView()
    private let progressRing = CircularProgressView()
    private let progressTick = PassthroughImageView()
    private let progressLabel = NSTextField(labelWithString: "")
    private var player: AVPlayer?
    private var loopObserver: NSObjectProtocol?

    private(set) var isHovered = false
    private enum UploadState { case idle, uploading, done }
    private var uploadState = UploadState.idle
    /// True while an upload of this media runs (or its done tick shows) — started from the card or anywhere else
    /// (after-capture action, history, menu); driven by `CapturedMedia.uploadProgress`.
    var isUploading: Bool { uploadState != .idle }
    private var linkBeforeUpload: URL?
    private var lastFraction = 0.0
    private var uploadWatchdog: Timer?
    private(set) var isDragging = false
    private(set) var isClosing = false
    private var mouseDownPoint: NSPoint?
    private var swipeOffset = CGSize.zero
    private var autoCloseWork: DispatchWorkItem?
    private var showsTrash = false

    /// Frame assigned by the last layout pass (nil = hidden because the stack is full or slid down).
    var targetFrame: CGRect?
    /// Set by the controller once the entrance has started (it waits for the first thumbnail).
    var hasEntered = false
    private(set) var hasThumbnail = false
    private var thumbnailWaiters: [() -> Void] = []

    init(media: CapturedMedia) {
        self.media = media
        panel = OverlayWindow.makePanel(NSRect(origin: .zero, size: QuickAccessLayout.cardSize(sizeIndex: Defaults[.quickAccessSizeIndex])),
                                        level: OverlayWindow.quickAccessLevel)
        super.init()
        root.card = self
        buildUI()
        panel.contentView = root
        reloadThumbnail()
        scheduleAutoClose()
    }

    // MARK: UI

    private func buildUI() {
        let radius = OverlayStyle.cardCornerRadius
        root.wantsLayer = true
        root.layer?.cornerRadius = radius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true

        // Glass behind the thumbnail (visible through transparent captures).
        chrome.material = .hudWindow
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.maskImage = .roundedMask(radius: radius)
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)

        thumb.autoresizingMask = [.width, .height]
        root.addSubview(thumb)

        buildHoverOverlay()
        buildProgressOverlay()

        let stroke = CardStrokeView(radius: radius)
        stroke.autoresizingMask = [.width, .height]
        root.addSubview(stroke)

        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Quick Access: \(media.url.lastPathComponent)")
    }

    private func buildHoverOverlay() {
        hoverOverlay.autoresizingMask = [.width, .height]
        hoverOverlay.alphaValue = 0
        root.addSubview(hoverOverlay)

        // Dimmed, frosted thumbnail.
        frost.material = .hudWindow
        frost.blendingMode = .withinWindow
        frost.state = .active
        frost.appearance = NSAppearance(named: .darkAqua)
        frost.wantsLayer = true
        frost.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        frost.autoresizingMask = [.width, .height]
        hoverOverlay.addSubview(frost)

        // Hover buttons (CleanShot `PopupBasic`, binary): light vibrant pills and circles with `labelColor` content.
        let copy = OverlayButton(.pill("Copy"), backdrop: .vibrant, tooltip: "Copy to clipboard (⌘C)") { [weak self] in self?.copy() }
        let secondary = OverlayButton(.pill("Save"), backdrop: .vibrant, tooltip: "Save (⌘S)") { [weak self] in self?.saveOrTrash() }
        secondaryPill = secondary
        let center = NSStackView(views: [copy, secondary])
        center.orientation = .vertical
        center.alignment = .centerX
        center.distribution = .fill
        center.spacing = 10
        center.setHuggingPriority(.required, for: .vertical)
        center.setHuggingPriority(.required, for: .horizontal)
        center.translatesAutoresizingMaskIntoConstraints = false
        hoverOverlay.addSubview(center)

        let close = OverlayButton(.icon("xmark"), backdrop: .vibrant, tooltip: "Close (⌘W)") { [weak self] in self?.close(recordForRestore: true) }
        let topRight = media.isImage
            ? OverlayButton(.icon("pin.fill"), backdrop: .vibrant, tooltip: "Pin to the screen (⌘P)") { [weak self] in self?.pin() }
            : OverlayButton(.icon("eye"), backdrop: .vibrant, tooltip: "Open Quick Look (Space)") { [weak self] in self?.quickLook() }
        let edit = OverlayButton(.icon(media.isImage ? "pencil" : "scissors"), backdrop: .vibrant,
                                 tooltip: MediaActions.editTitle(for: media)) { [weak self] in self?.edit() }
        let upload = OverlayButton(.icon("icloud.and.arrow.up.fill"), backdrop: .vibrant, tooltip: "Upload (⌘U)") { [weak self] in
            self?.upload()
        }
        uploadButton = upload
        cornerButtons = [close, topRight, edit, upload]
        cornerButtons.forEach(hoverOverlay.addSubview)
        updateCornerButtonSize()
        updateUploadButtonVisibility()

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.isHidden = !media.isVideoLike
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        hoverOverlay.addSubview(durationLabel)

        let inset: CGFloat = 6
        NSLayoutConstraint.activate([
            copy.widthAnchor.constraint(equalTo: secondary.widthAnchor),
            center.centerXAnchor.constraint(equalTo: hoverOverlay.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: hoverOverlay.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: hoverOverlay.leadingAnchor, constant: inset),
            close.topAnchor.constraint(equalTo: hoverOverlay.topAnchor, constant: inset),
            topRight.trailingAnchor.constraint(equalTo: hoverOverlay.trailingAnchor, constant: -inset),
            topRight.topAnchor.constraint(equalTo: hoverOverlay.topAnchor, constant: inset),
            edit.leadingAnchor.constraint(equalTo: hoverOverlay.leadingAnchor, constant: inset),
            edit.bottomAnchor.constraint(equalTo: hoverOverlay.bottomAnchor, constant: -inset),
            upload.trailingAnchor.constraint(equalTo: hoverOverlay.trailingAnchor, constant: -inset),
            upload.bottomAnchor.constraint(equalTo: hoverOverlay.bottomAnchor, constant: -inset),
            durationLabel.centerXAnchor.constraint(equalTo: hoverOverlay.centerXAnchor),
            durationLabel.centerYAnchor.constraint(equalTo: edit.centerYAnchor),
        ])
        updateSecondaryPill()
    }

    private func buildProgressOverlay() {
        progressOverlay.material = .hudWindow
        progressOverlay.blendingMode = .withinWindow
        progressOverlay.state = .active
        progressOverlay.appearance = NSAppearance(named: .darkAqua)
        progressOverlay.autoresizingMask = [.width, .height]
        progressOverlay.isHidden = true
        root.addSubview(progressOverlay)

        progressRing.translatesAutoresizingMaskIntoConstraints = false
        progressTick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Uploaded")?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .semibold))
        progressTick.contentTintColor = .white
        progressTick.isHidden = true
        progressTick.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        progressLabel.textColor = .white
        progressLabel.alignment = .center
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        [progressRing, progressTick, progressLabel].forEach(progressOverlay.addSubview)
        NSLayoutConstraint.activate([
            progressRing.centerXAnchor.constraint(equalTo: progressOverlay.centerXAnchor),
            progressRing.centerYAnchor.constraint(equalTo: progressOverlay.centerYAnchor),
            progressRing.widthAnchor.constraint(equalToConstant: 40),
            progressRing.heightAnchor.constraint(equalToConstant: 40),
            progressTick.centerXAnchor.constraint(equalTo: progressRing.centerXAnchor),
            progressTick.centerYAnchor.constraint(equalTo: progressRing.centerYAnchor),
            progressLabel.centerXAnchor.constraint(equalTo: progressRing.centerXAnchor),
            progressLabel.centerYAnchor.constraint(equalTo: progressRing.centerYAnchor),
        ])
    }

    /// Corner circles grow with the "Overlay size" setting.
    func updateCornerButtonSize() {
        let side = QuickAccessLayout.cornerButtonSide(sizeIndex: Defaults[.quickAccessSizeIndex])
        cornerButtons.forEach { $0.side = side }
    }

    func updateUploadButtonVisibility() {
        uploadButton.isHidden = !Defaults[.quickAccessShowUploadButton] || isUploading
    }

    /// With the file already saved (e.g. an auto-save after-capture action), Save is pointless: Trash replaces it.
    private func updateSecondaryPill() {
        let trash = media.isSaved
        guard trash != showsTrash else { return }
        showsTrash = trash
        secondaryPill.apply(trash ? .symbolPill("trash") : .pill("Save"), tooltip: trash ? "Move to Trash" : "Save (⌘S)")
    }

    /// Reloads the thumbnail, duration and buttons after edits, saves, renames or uploads.
    func mediaDidChange() {
        reloadThumbnail()
        updateSecondaryPill()
        if uploadState == .uploading, media.uploadedURL != nil, media.uploadedURL != linkBeforeUpload { uploadSucceeded() }
    }

    private func reloadThumbnail() {
        root.setAccessibilityLabel("Quick Access: \(media.url.lastPathComponent)")
        let url = media.url
        if media.kind == .gif {
            thumb.setImage(NSImage(contentsOf: url), animated: true)
            thumbnailDidLoad()
        } else {
            let size = QuickAccessLayout.cardSize(sizeIndex: Defaults[.quickAccessSizeIndex])
            let px = QuickAccessLayout.thumbnailMaxPixel(card: size, media: media.pixelSize,
                                                         backingScale: (panel.screen ?? NSScreen.active).backingScaleFactor)
            Thumbnailer.thumbnail(for: url, kind: media.kind, maxPixel: px) { [weak self] img in
                guard let self, self.media.url == url else { return }
                self.thumb.setImage(img, animated: false)
                self.thumbnailDidLoad()
            }
        }
        if media.isVideoLike && media.kind != .studioProject {
            let asset = AVURLAsset(url: url)
            Task { @MainActor [weak self] in
                guard let d = try? await asset.load(.duration), let self, self.media.url == url else { return }
                self.durationLabel.stringValue = OverlayFormat.duration(d.seconds)
            }
        }
    }

    /// Runs `body` once the first thumbnail is shown (immediately if it already is).
    func whenThumbnailReady(_ body: @escaping () -> Void) {
        if hasThumbnail { body() } else { thumbnailWaiters.append(body) }
    }

    private func thumbnailDidLoad() {
        hasThumbnail = true
        let waiters = thumbnailWaiters
        thumbnailWaiters.removeAll()
        waiters.forEach { $0() }
    }

    // MARK: Hover

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered, !isClosing else { return }
        isHovered = hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = QuickAccessMotion.hoverFade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverOverlay.animator().alphaValue = hovered && !isUploading ? 1 : 0
        }
        if hovered {
            autoCloseWork?.cancel()
            HoverHotkeys.shared.activate(owner: self, hotkeyBindings())
            startHoverPlayback()
            QuickAccessController.shared.cardWasHovered(self)
        } else {
            HoverHotkeys.shared.deactivate(owner: self)
            stopHoverPlayback()
            scheduleAutoClose()
        }
    }

    /// Re-derives the hover state from the pointer. Tracking areas only fire on pointer movement, so a card that
    /// moves under (or away from) a still pointer would otherwise stay "hovered" — keeping its global hotkeys
    /// registered and its auto-close suspended.
    func syncHoverWithPointer() {
        guard !isClosing, !isDragging, NSEvent.pressedMouseButtons == 0 else { return }
        let inside = panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        if inside != isHovered { setHovered(inside) }
    }

    private func hotkeyBindings() -> [HoverHotkeys.Binding] {
        [
            .init(Keys.c, .command) { [weak self] in self?.copy() },
            .init(Keys.s, .command) { [weak self] in self?.save() },
            .init(Keys.e, .command) { [weak self] in self?.edit() },
            .init(Keys.p, .command) { [weak self] in self?.pin() },
            .init(Keys.u, .command) { [weak self] in self?.upload() },
            .init(Keys.w, .command) { [weak self] in self?.close(recordForRestore: true) },
            .init(Keys.escape) { [weak self] in self?.close(recordForRestore: true) },
            .init(Keys.space) { [weak self] in self?.quickLook() },
        ]
    }

    private func startHoverPlayback() {
        guard media.kind == .video, player == nil, !isUploading else { return }
        let p = AVPlayer(url: media.url)
        p.isMuted = true
        p.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem,
                                                              queue: .main) { [weak p] _ in p?.seek(to: .zero); p?.play() }
        player = p
        thumb.attach(p)
        p.play()
    }

    private func stopHoverPlayback() {
        player?.pause()
        thumb.attach(nil)
        if let o = loopObserver { NotificationCenter.default.removeObserver(o) }
        loopObserver = nil
        player = nil
    }

    // MARK: Auto close

    func scheduleAutoClose() {
        autoCloseWork?.cancel()
        guard Defaults[.quickAccessAutoClose], !isHovered, !isUploading, !isDragging, !isClosing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosing else { return }
            // Something started since scheduling: the state change that ends it reschedules.
            guard !self.isHovered, !self.isUploading, !self.isDragging else { return }
            if let action = Defaults[.quickAccessAutoCloseAction] { MediaPipeline.perform(action, on: self.media) }
            // An upload action keeps the card until it finishes (then "close after uploading" applies).
            if self.isUploading { return }
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
        if MediaActions.save(media, forceAsk: forceAsk || NSEvent.modifierFlags.contains(.option)) { close(recordForRestore: true) }
    }

    private func saveOrTrash() {
        if showsTrash { MediaActions.moveToTrash(media) } else { save() }
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
        let configured = Services.upload?.isConfigured ?? false
        if configured { uploadStarted() }
        // UploadKit explains a missing destination, shows errors, plays the sound and the "Link has been copied" HUD.
        MediaActions.upload(media) { [weak self] result in
            guard let self, self.uploadState == .uploading else { return }
            if case .success = result { self.uploadSucceeded() } else { self.uploadEnded() }
        }
    }

    // MARK: Upload progress (from this card or any other caller)

    func uploadProgressed(_ fraction: Double) {
        guard !isClosing, uploadState != .done else { return }
        if uploadState == .idle { uploadStarted() }
        lastFraction = fraction
        progressRing.progress = fraction
        progressLabel.stringValue = "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private func uploadStarted() {
        guard uploadState == .idle, !isClosing else { return }
        uploadState = .uploading
        linkBeforeUpload = media.uploadedURL
        lastFraction = 0
        autoCloseWork?.cancel()
        stopHoverPlayback()
        updateUploadButtonVisibility()
        hoverOverlay.alphaValue = 0
        progressRing.progress = 0
        progressRing.isHidden = false
        progressLabel.stringValue = ""
        progressLabel.isHidden = false
        progressTick.isHidden = true
        progressOverlay.isHidden = false
        // Uploads started elsewhere report no failure to us: end the progress state once UploadKit goes idle.
        uploadWatchdog?.invalidate()
        let t = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.uploadState == .uploading, !(Services.upload?.isUploading ?? false) else { return }
                let newLink = self.media.uploadedURL.map { $0 != self.linkBeforeUpload } ?? false
                if newLink || self.lastFraction >= 1 { self.uploadSucceeded() } else { self.uploadEnded() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        uploadWatchdog = t
    }

    private func uploadSucceeded() {
        guard uploadState == .uploading else { return }
        uploadState = .done
        uploadWatchdog?.invalidate()
        uploadWatchdog = nil
        progressRing.isHidden = true
        progressLabel.isHidden = true
        progressTick.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.isClosing else { return }
            if Defaults[.quickAccessCloseAfterUploading] { self.close(recordForRestore: true) } else { self.uploadEnded() }
        }
    }

    /// Back to the normal card (after success without auto-close, failure or cancellation).
    private func uploadEnded() {
        uploadWatchdog?.invalidate()
        uploadWatchdog = nil
        uploadState = .idle
        progressOverlay.isHidden = true
        updateUploadButtonVisibility()
        if isHovered {
            hoverOverlay.alphaValue = 1
            startHoverPlayback()
        }
        scheduleAutoClose()
    }

    func close(recordForRestore: Bool) {
        guard !isClosing else { return }
        isClosing = true
        autoCloseWork?.cancel()
        uploadWatchdog?.invalidate()
        uploadWatchdog = nil
        HoverHotkeys.shared.deactivate(owner: self)
        stopHoverPlayback()
        if QuickLookController.shared.currentURL == media.url { QuickLookController.shared.close() }
        QuickAccessController.shared.cardDidClose(self, recordForRestore: recordForRestore)
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        if event.clickCount == 2 { mouseDownPoint = nil; edit() }
    }

    func mouseDragged(_ event: NSEvent) {
        guard !isDragging, !isUploading, !isClosing, let start = mouseDownPoint else { return }
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
        item.setDraggingFrame(root.bounds, contents: image)
        isDragging = true
        autoCloseWork?.cancel()
        HoverHotkeys.shared.deactivate(owner: self)
        let session = root.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        PanelMotion.shared.finish(panel)   // an entrance or reflow still running lands first
        PanelMotion.shared.fade(panel, to: 0.35, curve: .easeOut(0.15))
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { dragEnded(at: screenPoint, operation: operation) }
    }

    private func dragEnded(at point: NSPoint, operation: NSDragOperation) {
        isDragging = false
        guard !isClosing else { return }      // closed meanwhile (Close All, trash, …): let its fade-out run
        PanelMotion.shared.finish(panel)
        panel.alphaValue = 1
        let keep = NSEvent.modifierFlags.contains(.option)   // "hold ⌥ to keep it"
        let screen = panel.screen ?? NSScreen.active
        if operation != [] {
            if Defaults[.quickAccessCloseAfterDragging] && !keep { close(recordForRestore: true); return }
        } else if QuickAccessLayout.isAtEdge(point, of: screen.frame, side: Defaults[.quickAccessSide]) {
            close(recordForRestore: true); return   // flung to the screen edge → dismiss
        }
        // Re-derive hover: the drop may have ended anywhere.
        if panel.frame.contains(NSEvent.mouseLocation) {
            if isHovered { HoverHotkeys.shared.activate(owner: self, hotkeyBindings()) } else { setHovered(true) }
        } else if isHovered {
            setHovered(false)
        } else {
            scheduleAutoClose()
        }
    }

    /// Two-finger swipe toward the screen edge dismisses the card; swiping down slides the whole stack away.
    func scroll(_ event: NSEvent) {
        guard !isClosing, !isDragging, let target = targetFrame else { return }
        let side = Defaults[.quickAccessSide]
        let inverted = event.isDirectionInvertedFromDevice
        let fingerDX = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let fingerDY = inverted ? event.scrollingDeltaY : -event.scrollingDeltaY   // > 0 = fingers move down
        if event.phase == .began { PanelMotion.shared.finish(panel) }   // the swipe takes over from any running motion
        switch event.phase {
        case .began, .changed:
            if swipeOffset == .zero && abs(fingerDY) > abs(fingerDX) {
                swipeOffset.height += fingerDY       // vertical gesture: tracked, applied on release
                return
            }
            if swipeOffset.height != 0 { swipeOffset.height += fingerDY; return }
            swipeOffset.width += fingerDX
            // Only toward the edge (a little rubber band inward).
            swipeOffset.width = side == .left ? min(swipeOffset.width, 12) : max(swipeOffset.width, -12)
            panel.setFrameOrigin(NSPoint(x: target.minX + swipeOffset.width, y: target.minY))
        case .ended, .cancelled:
            let offset = swipeOffset
            swipeOffset = .zero
            if offset.height > 24 { QuickAccessController.shared.slideDown(); return }
            guard offset.width != 0 else { return }
            let dismiss = abs(offset.width) > target.width * 0.35 && (side == .left ? offset.width < 0 : offset.width > 0)
            if dismiss { close(recordForRestore: true) } else {
                PanelMotion.shared.move(panel, to: target, curve: .easeOut(0.2))
            }
        default:
            break
        }
    }

    // MARK: Context menu

    func showContextMenu(_ event: NSEvent, in view: NSView) {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ClosureMenuItem(media.isImage ? "Open Annotation Tool…" : "Open Video Editor…", key: "e",
                                  symbol: media.isImage ? "pencil" : "scissors") { [weak self] in self?.edit() })
        if media.isImage { m.addItem(ClosureMenuItem("Pin to the Screen", key: "p", symbol: "pin") { [weak self] in self?.pin() }) }
        m.addItem(.separator())
        let upload = ClosureMenuItem("Upload to Cloud", key: "u", symbol: "icloud.and.arrow.up") { [weak self] in self?.upload() }
        upload.isEnabled = !isUploading
        m.addItem(upload)
        m.addItem(ClosureMenuItem("Quick Look", key: " ", modifiers: [], symbol: "eye") { [weak self] in self?.quickLook() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { [weak self] in if let self { MediaActions.showInFinder(self.media) } })
        m.addItem(MediaActions.openWithMenuItem(for: media))
        m.addItem(ClosureMenuItem("Copy", key: "c", symbol: "doc.on.doc") { [weak self] in self?.copy() })
        m.addItem(ClosureMenuItem("Save As…", key: "s", modifiers: [.command, .shift], symbol: "square.and.arrow.down") { [weak self] in
            self?.save(forceAsk: true)
        })
        m.addItem(ClosureMenuItem("Rename…", symbol: "pencil.line") { [weak self] in if let self { MediaActions.rename(self.media) } })
        m.addItem(NSSharingServicePicker(items: [media.url as NSURL]).standardShareMenuItem)
        m.addItem(ClosureMenuItem("Move to Trash", symbol: "trash") { [weak self] in if let self { MediaActions.moveToTrash(self.media) } })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Temporarily Hide") { QuickAccessController.shared.slideDown() })
        m.addItem(ClosureMenuItem("Close", key: "w") { [weak self] in self?.close(recordForRestore: true) })
        if QuickAccessController.shared.cards.count > 1 {
            m.addItem(ClosureMenuItem("Save All") { QuickAccessController.shared.saveAll() })
            m.addItem(ClosureMenuItem("Close All…") { QuickAccessController.shared.closeAll() })
        }
        NSMenu.popUpContextMenu(m, with: event, for: view)
    }
}
