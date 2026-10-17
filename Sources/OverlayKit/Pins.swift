import AppKit
import UniformTypeIdentifiers
import SuperScreenshotCore

// Pinned screenshots (CleanShot's `FloatingOverlay` / `FloatingOverlayController`).

@MainActor
final class PinController: PinServicing {
    static let shared = PinController()
    private(set) var pins: [PinOverlay] = []
    var hasPins: Bool { !pins.isEmpty }
    private var hidden = false
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: CapturedMedia.didChange, object: nil, queue: .main) { [weak self] n in
            guard let media = n.object as? CapturedMedia else { return }
            MainActor.assumeIsolated { self?.pins.filter { $0.media?.id == media.id }.forEach { $0.mediaDidChange() } }
        }
    }

    // MARK: PinServicing

    func pin(_ media: CapturedMedia) {
        guard media.isImage, let image = media.image else { NSSound.beep(); return }
        add(PinOverlay(image: image, media: media, sourceURL: media.url))
    }

    func pin(image: NSImage, sourceURL: URL?) {
        add(PinOverlay(image: image, media: nil, sourceURL: sourceURL))
    }

    func pinWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose and Pin an Image"
        panel.prompt = "Pin"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let img = NSImage(contentsOf: url) else { Alerts.error("“\(url.lastPathComponent)” isn't an image Super Screenshot can open."); continue }
            // Respect the file's DPI so Retina captures pin at their point size.
            if let rep = img.representations.first, rep.pixelsWide > 0, rep.size.width > 0 { img.size = rep.size }
            pin(image: img, sourceURL: url)
        }
    }

    func toggleVisibility() {
        guard !pins.isEmpty else { NSSound.beep(); return }
        hidden.toggle()
        pins.forEach { $0.setHidden(hidden) }
    }

    func closeAll() {
        pins.forEach { $0.close() }
    }

    // MARK: Internal

    func close(mediaID: UUID) {
        pins.filter { $0.media?.id == mediaID }.forEach { $0.close() }
    }

    func pinDidClose(_ pin: PinOverlay) {
        pins.removeAll { $0 === pin }
        if pins.isEmpty { hidden = false }
    }

    private func add(_ pin: PinOverlay) {
        if hidden { hidden = false; pins.forEach { $0.setHidden(false) } }
        let screen = NSScreen.active
        let cascade = CGFloat(pins.filter { $0.panel.screen == screen }.count % 8) * 24
        pin.present(on: screen, cascadeOffset: cascade)
        pins.append(pin)
    }
}

// MARK: - Pin window

final class PinContentView: NSView {
    weak var pin: PinOverlay?
    private var hoverArea: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTracking(on: self, existing: &hoverArea)
    }
    override func mouseEntered(with event: NSEvent) { pin?.setHovered(true) }
    override func mouseExited(with event: NSEvent) { pin?.setHovered(false) }
    override func mouseDown(with event: NSEvent) { pin?.mouseDown(event) }
    override func rightMouseDown(with event: NSEvent) { pin?.showContextMenu(event, in: self) }
    /// Middle-click closes the pin.
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { pin?.close() } }
    override func scrollWheel(with event: NSEvent) { pin?.scroll(event) }
    override func magnify(with event: NSEvent) { pin?.magnify(event) }
}

/// "Drag me" handle at the bottom centre that drags the pinned image out as a file (`FODragButton`).
final class PinDragHandle: NSVisualEffectView, NSDraggingSource {
    var fileURL: () -> URL? = { nil }
    var dragImage: () -> NSImage? = { nil }
    private var downPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        let label = NSTextField(labelWithString: "Drag me")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22), widthAnchor.constraint(equalTo: label.widthAnchor, constant: 22),
        ])
        toolTip = "Drag to copy the image to another app"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag me")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (frame.contains(point) ? self : nil) }
    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3,
              let url = fileURL() else { return }
        downPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = dragImage() ?? NSWorkspace.shared.icon(forFile: url.path)
        let w: CGFloat = 120, h = img.size.width > 0 ? w * img.size.height / img.size.width : w
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), contents: img)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }
}

@MainActor
final class PinOverlay: NSObject {
    private(set) var media: CapturedMedia?
    private var image: NSImage
    private var sourceURL: URL?
    private var tempURL: URL?
    let panel: OverlayPanel

    private let content = PinContentView()
    private let imageView = PassthroughImageView()
    private let zoomLabel = NSTextField(labelWithString: "")
    private var closeButton: OverlayButton!
    private var lockButton: OverlayButton!
    private let dragHandle = PinDragHandle()
    private var unlockPanel: OverlayPanel?
    private var lockTimer: Timer?
    private var zoomHideWork: DispatchWorkItem?

    private var magnification: CGFloat = 1
    private var opacity: CGFloat = 1
    private var showShadow = Defaults[.pinShowShadow]
    private var roundedCorners = true
    private var showBorder = false
    private var isLocked = false
    private var isHovered = false
    private var isClosing = false
    private var lockedHoverActive = false

    private var imageSize: CGSize { image.size.width > 0 ? image.size : CGSize(width: 200, height: 200) }

    init(image: NSImage, media: CapturedMedia?, sourceURL: URL?) {
        self.image = image
        self.media = media
        self.sourceURL = sourceURL
        panel = OverlayWindow.makePanel(NSRect(origin: .zero, size: image.size), level: OverlayWindow.pinLevel)
        super.init()
        content.pin = self
        buildUI()
        panel.contentView = content
        applyChrome()
    }

    // MARK: UI

    private func buildUI() {
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        content.addSubview(imageView)

        closeButton = OverlayButton(.icon("xmark"), tooltip: "Close (Esc)") { [weak self] in self?.close() }
        lockButton = OverlayButton(.icon("lock.open.fill"), tooltip: "Lock (click-through)") { [weak self] in self?.setLocked(true) }
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.fileURL = { [weak self] in self?.fileForDragging() }
        dragHandle.dragImage = { [weak self] in self?.image }

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        zoomLabel.textColor = .white
        zoomLabel.alignment = .center
        zoomLabel.wantsLayer = true
        zoomLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        zoomLabel.layer?.cornerRadius = 6
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.alphaValue = 0

        [closeButton!, lockButton!, dragHandle, zoomLabel].forEach { v in
            content.addSubview(v)
            if v !== zoomLabel { v.alphaValue = 0 }
        }
        let inset: CGFloat = 8
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            lockButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            lockButton.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            dragHandle.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dragHandle.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
            zoomLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            zoomLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            zoomLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.image)
        content.setAccessibilityLabel("Pinned screenshot")
    }

    private func applyChrome() {
        content.layer?.cornerRadius = roundedCorners ? OverlayStyle.pinCornerRadius : 0
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = showBorder ? 1 : 0
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.hasShadow = showShadow
        panel.alphaValue = lockedHoverActive && Defaults[.pinLockAndHideOnHover] ? 0.05 : opacity
        panel.invalidateShadow()
    }

    func present(on screen: NSScreen, cascadeOffset: CGFloat) {
        let vis = screen.visibleFrame
        magnification = PinGeometry.fittingMagnification(imageSize: imageSize, visible: vis)
        let size = CGSize(width: (imageSize.width * magnification).rounded(), height: (imageSize.height * magnification).rounded())
        var frame = CGRect(x: (vis.midX - size.width / 2 + cascadeOffset).rounded(),
                           y: (vis.midY - size.height / 2 - cascadeOffset).rounded(), width: size.width, height: size.height)
        frame.origin.y = max(vis.minY, frame.origin.y)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = opacity
        }
    }

    func setHidden(_ hidden: Bool) {
        if hidden {
            panel.orderOut(nil)
            unlockPanel?.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: Hover / keyboard

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered, !isClosing else { return }
        isHovered = hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = OverlayStyle.hoverFade
            [closeButton!, lockButton!, dragHandle].forEach { $0.animator().alphaValue = hovered ? 1 : 0 }
        }
        if hovered { HoverHotkeys.shared.activate(owner: self, hotkeyBindings()) } else { HoverHotkeys.shared.deactivate(owner: self) }
    }

    private func hotkeyBindings() -> [HoverHotkeys.Binding] {
        var b: [HoverHotkeys.Binding] = [
            .init(Keys.c, .command) { [weak self] in self?.copy() },
            .init(Keys.s, .command) { [weak self] in self?.save(forceAsk: false) },
            .init(Keys.e, .command) { [weak self] in self?.annotate() },
            .init(Keys.w, .command) { [weak self] in self?.close() },
            .init(Keys.escape) { [weak self] in self?.close() },
        ]
        let arrows: [(Int, CGFloat, CGFloat)] = [(Keys.left, -1, 0), (Keys.right, 1, 0), (Keys.up, 0, 1), (Keys.down, 0, -1)]
        for (key, dx, dy) in arrows {
            b.append(.init(key) { [weak self] in self?.move(dx: dx, dy: dy) })
            b.append(.init(key, .shift) { [weak self] in self?.move(dx: dx * 10, dy: dy * 10) })
        }
        return b
    }

    private func move(dx: CGFloat, dy: CGFloat) {
        var f = panel.frame
        f.origin.x += dx
        f.origin.y += dy
        panel.setFrame(f, display: true)
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        if event.clickCount == 2 { annotate(); return }
        panel.performDrag(with: event)
    }

    func scroll(_ event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? dy * 0.005 : dy * 0.05
        if event.modifierFlags.contains(.option) {
            setOpacity(opacity + step)
        } else {
            zoom(to: magnification * (1 + step), anchor: NSEvent.mouseLocation)
        }
    }

    func magnify(_ event: NSEvent) {
        zoom(to: magnification * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    private func zoom(to m: CGFloat, anchor: CGPoint? = nil) {
        let clamped = min(max(m, PinGeometry.minMagnification), PinGeometry.maxMagnification)
        let a = anchor.flatMap { panel.frame.contains($0) ? $0 : nil } ?? CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        magnification = clamped
        panel.setFrame(PinGeometry.scaled(frame: panel.frame, imageSize: imageSize, magnification: clamped, anchor: a), display: true)
        panel.invalidateShadow()
        flashLabel("\(Int((clamped * 100).rounded()))%")
    }

    private func setOpacity(_ value: CGFloat) {
        opacity = min(max(value, 0.1), 1)
        applyChrome()
        flashLabel("Opacity \(Int((opacity * 100).rounded()))%")
    }

    private func flashLabel(_ text: String) {
        zoomLabel.stringValue = " \(text) "
        zoomLabel.alphaValue = 1
        zoomHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self.zoomLabel.animator().alphaValue = 0 }
        }
        zoomHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: Lock

    private func setLocked(_ locked: Bool) {
        isLocked = locked
        panel.ignoresMouseEvents = locked
        if locked {
            setHovered(false)
            let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollLockedHover() }
            }
            RunLoop.main.add(t, forMode: .common)
            lockTimer = t
        } else {
            lockTimer?.invalidate()
            lockTimer = nil
            lockedHoverActive = false
            unlockPanel?.orderOut(nil)
            applyChrome()
            // No mouseEntered arrives for a pointer that is already inside: show the chrome now.
            if panel.isVisible && panel.frame.contains(NSEvent.mouseLocation) { setHovered(true) }
        }
    }

    /// While locked the pin is click-through; a small unlock button floats over its corner when the pointer is over it.
    private func pollLockedHover() {
        guard isLocked, panel.isVisible else { unlockPanel?.orderOut(nil); return }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        guard inside != lockedHoverActive else { return }
        lockedHoverActive = inside
        if inside {
            let up = unlockPanel ?? makeUnlockPanel()
            let f = panel.frame
            up.setFrame(NSRect(x: f.maxX - 33, y: f.maxY - 33, width: 28, height: 28), display: true)
            if up.parent == nil { panel.addChildWindow(up, ordered: .above) }
            up.orderFrontRegardless()
        } else {
            unlockPanel?.orderOut(nil)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = inside && Defaults[.pinLockAndHideOnHover] ? 0.05 : opacity
        }
    }

    private func makeUnlockPanel() -> OverlayPanel {
        let p = OverlayWindow.makePanel(NSRect(x: 0, y: 0, width: 28, height: 28), level: OverlayWindow.pinLevel)
        p.hasShadow = false
        let v = NSView()
        let b = OverlayButton(.icon("lock.fill"), tooltip: "Unlock") { [weak self] in self?.setLocked(false) }
        v.addSubview(b)
        NSLayoutConstraint.activate([b.centerXAnchor.constraint(equalTo: v.centerXAnchor), b.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        p.contentView = v
        unlockPanel = p
        return p
    }

    // MARK: Actions

    private func copy() {
        if let media { Clipboard.copy(media) } else if let cg = image.cgImage { Clipboard.copy(image: cg) }
        HUD.show("Copied to clipboard")
    }

    private func save(forceAsk: Bool) {
        if let media { MediaActions.save(media, forceAsk: forceAsk); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (sourceURL?.deletingPathExtension().lastPathComponent ?? "Pinned Image") + ".png"
        panel.directoryURL = AppPaths.exportLocation
        panel.allowedContentTypes = [.png]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let cg = image.cgImage else { return }
        do {
            try ImageTools.write(cg, to: url, format: .png, scale: CGFloat(cg.width) / max(imageSize.width, 1))
        } catch {
            Alerts.error("Something went wrong saving your file.", error)
        }
    }

    private func annotate() {
        if let media { MediaActions.edit(media); return }
        guard let url = fileForDragging() else { NSSound.beep(); return }
        Services.annotate?.open(fileURL: url)
    }

    private func fileForDragging() -> URL? {
        if let media, FileManager.default.fileExists(atPath: media.url.path) { return media.url }
        if let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) { return sourceURL }
        if let tempURL, FileManager.default.fileExists(atPath: tempURL.path) { return tempURL }
        tempURL = MediaActions.temporaryFile(for: image)
        return tempURL
    }

    func mediaDidChange() {
        guard let media, let img = media.image else { return }
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        image = img
        imageView.image = img
        let size = CGSize(width: (imageSize.width * magnification).rounded(), height: (imageSize.height * magnification).rounded())
        panel.setFrame(CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        setLocked(false)
        zoomHideWork?.cancel()
        HoverHotkeys.shared.deactivate(owner: self)
        if let up = unlockPanel { panel.removeChildWindow(up); up.orderOut(nil) }
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        PinController.shared.pinDidClose(self)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { self.panel.orderOut(nil) }
        })
    }

    // MARK: Context menu

    func showContextMenu(_ event: NSEvent, in view: NSView) {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("Copy to Clipboard", key: "c", symbol: "doc.on.doc") { [weak self] in self?.copy() })
        m.addItem(ClosureMenuItem("Save", key: "s", symbol: "square.and.arrow.down") { [weak self] in self?.save(forceAsk: false) })
        m.addItem(ClosureMenuItem("Save As…", key: "s", modifiers: [.command, .shift]) { [weak self] in self?.save(forceAsk: true) })
        if Services.text != nil {
            m.addItem(ClosureMenuItem("Capture Text", symbol: "text.viewfinder") { [weak self] in
                if let cg = self?.media?.cgImage ?? self?.image.cgImage { MediaActions.copyText(from: cg) }
            })
        }
        m.addItem(ClosureMenuItem("Open Annotation Tool…", key: "e", symbol: "pencil") { [weak self] in self?.annotate() })
        if let media {
            m.addItem(ClosureMenuItem("Upload to Cloud", symbol: "icloud.and.arrow.up") { MediaActions.upload(media) })
        }
        m.addItem(.separator())

        let zoomMenu = NSMenu()
        for pct in [25, 50, 75, 100, 150, 200] {
            zoomMenu.addItem(ClosureMenuItem("\(pct)%", state: Int((magnification * 100).rounded()) == pct ? .on : .off) { [weak self] in
                self?.zoom(to: CGFloat(pct) / 100)
            })
        }
        let zoomItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        zoomItem.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)
        zoomItem.submenu = zoomMenu
        m.addItem(zoomItem)

        let opacityMenu = NSMenu()
        for pct in [100, 75, 50, 25] {
            opacityMenu.addItem(ClosureMenuItem("\(pct)%", state: Int((opacity * 100).rounded()) == pct ? .on : .off) { [weak self] in
                self?.setOpacity(CGFloat(pct) / 100)
            })
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        opacityItem.submenu = opacityMenu
        m.addItem(opacityItem)

        m.addItem(ClosureMenuItem("Show Shadow", state: showShadow ? .on : .off) { [weak self] in
            guard let self else { return }
            self.showShadow.toggle(); self.applyChrome()
        })
        m.addItem(ClosureMenuItem("Rounded Corners", state: roundedCorners ? .on : .off) { [weak self] in
            guard let self else { return }
            self.roundedCorners.toggle(); self.applyChrome()
        })
        m.addItem(ClosureMenuItem("Border", state: showBorder ? .on : .off) { [weak self] in
            guard let self else { return }
            self.showBorder.toggle(); self.applyChrome()
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Lock (Click-Through)", symbol: "lock") { [weak self] in self?.setLocked(true) })
        m.addItem(ClosureMenuItem("Close", key: "w", symbol: "xmark") { [weak self] in self?.close() })
        m.addItem(ClosureMenuItem("Close All Pins") { PinController.shared.closeAll() })
        NSMenu.popUpContextMenu(m, with: event, for: view)
    }
}
