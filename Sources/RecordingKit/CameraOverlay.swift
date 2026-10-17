import AppKit
import AVFoundation
import SuperScreenshotCore

/// Floating webcam bubble (circle, square or rectangle) that is recorded together with the screen.
/// Sits at the bottom-right of the area. Drag to move, click to toggle full-screen camera, right-click for
/// device / shape / size / flip, scroll or pinch to resize.
@MainActor
final class CameraOverlay: NSObject {
    private let panel: RecorderPanel
    private let container = CameraView()
    private let spinner = NSProgressIndicator()
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    private var currentInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "superscreenshot.recording.camera")
    private var startObserver: NSObjectProtocol?

    /// Global rect of the recording area the bubble belongs to.
    private var area: CGRect
    /// Bubble height in points (width follows the shape's aspect).
    private var height: CGFloat
    private var isFullscreen = false
    /// Once the user drags the bubble it stays where they put it when the area changes.
    private var userMoved = false

    private static let inset: CGFloat = 16
    private static let border: CGFloat = 3

    var windowNumber: Int { panel.windowNumber }
    var onDisable: (() -> Void)?

    init(area: CGRect) {
        self.area = area
        height = Self.clampedHeight(Defaults[.rkCameraSize].points, area: area)
        panel = RecorderPanel(frame: .zero, level: RecorderLevel.camera, clickThrough: false)
        panel.hasShadow = true
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        preview.videoGravity = .resizeAspectFill
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.addSublayer(preview)
        container.menuProvider = { [weak self] in self?.makeMenu() }
        container.onScroll = { [weak self] delta in self?.resize(by: delta) }
        container.onDrag = { [weak self] delta in self?.move(by: delta) }
        container.onClick = { [weak self] in self?.toggleFullscreen() }
        container.toolTip = "Click to toggle full-screen camera. Right-click for options."
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false
        container.addSubview(spinner)
        panel.contentView = container
        startObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                               object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spinner.stopAnimation(nil) }
        }
        layout(frame: restingFrame())
        selectDevice(AVDevices.selectedCamera)
    }

    func show() {
        panel.orderFrontRegardless()
        spinner.startAnimation(nil)
        let s = UncheckedBox(session)
        sessionQueue.async { if !s.value.isRunning { s.value.startRunning() } }
    }

    func close() {
        if let startObserver { NotificationCenter.default.removeObserver(startObserver) }
        startObserver = nil
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
        let s = UncheckedBox(session)
        sessionQueue.async { s.value.stopRunning() }
    }

    /// Follows the recording area while it is being adjusted.
    func areaDidChange(_ newArea: CGRect) {
        area = newArea
        if isFullscreen { layout(frame: area) } else if !userMoved {
            height = Self.clampedHeight(Defaults[.rkCameraSize].points, area: area)
            layout(frame: restingFrame())
        }
    }

    // MARK: Geometry

    private static func clampedHeight(_ preferred: CGFloat, area: CGRect) -> CGFloat {
        min(preferred, max(80, min(area.width, area.height) * 0.6))
    }

    private var bubbleSize: CGSize {
        CGSize(width: (height * Defaults[.rkCameraShape].aspect).rounded(), height: height.rounded())
    }

    /// Bottom-right of the area, inset.
    private func restingFrame() -> NSRect {
        let s = bubbleSize
        return NSRect(x: area.maxX - Self.inset - s.width, y: area.minY + Self.inset, width: s.width, height: s.height)
    }

    private func layout(frame: NSRect) {
        panel.setFrame(frame, display: true)
        container.frame = NSRect(origin: .zero, size: frame.size)
        spinner.frame = NSRect(x: (frame.width - 16) / 2, y: (frame.height - 16) / 2, width: 16, height: 16)
        let shape = Defaults[.rkCameraShape]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = container.bounds
        if isFullscreen {
            container.layer?.cornerRadius = 0
            container.layer?.borderWidth = 0
        } else {
            container.layer?.cornerRadius = shape == .circle ? frame.height / 2 : min(frame.width, frame.height) * 0.14
            container.layer?.borderWidth = Self.border
            container.layer?.borderColor = NSColor.white.cgColor
        }
        container.layer?.cornerCurve = shape == .circle ? .circular : .continuous
        CATransaction.commit()
        panel.invalidateShadow()
    }

    private func move(by delta: CGSize) {
        guard !isFullscreen else { return }
        userMoved = true
        var f = panel.frame
        f.origin.x += delta.width
        f.origin.y += delta.height
        if let screen = panel.screen?.frame ?? NSScreen.screens.first(where: { $0.frame.intersects(area) })?.frame {
            f.origin.x = min(max(f.origin.x, screen.minX), screen.maxX - f.width)
            f.origin.y = min(max(f.origin.y, screen.minY), screen.maxY - f.height)
        }
        panel.setFrameOrigin(f.origin)
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        if isFullscreen {
            bubbleFrame = panel.frame
            layout(frame: area)
        } else {
            layout(frame: userMoved ? bubbleFrame ?? restingFrame() : restingFrame())
        }
    }

    /// Where the bubble was before going full screen.
    private var bubbleFrame: NSRect?

    private func resize(by delta: CGFloat) {
        guard !isFullscreen else { return }
        let screen = panel.screen?.frame.size ?? CGSize(width: 1440, height: 900)
        height = min(min(screen.width, screen.height) * 0.6, max(80, height + delta))
        let old = panel.frame
        let s = bubbleSize
        // Keep the bubble anchored at its centre.
        layout(frame: NSRect(x: old.midX - s.width / 2, y: old.midY - s.height / 2, width: s.width, height: s.height))
    }

    // MARK: Configuration

    private func selectDevice(_ device: AVCaptureDevice?) {
        guard let device else { return }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            Log.recording.error("Camera unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        session.beginConfiguration()
        if let currentInput { session.removeInput(currentInput) }
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        } else if let currentInput, session.canAddInput(currentInput) {
            session.addInput(currentInput)   // keep the previous camera rather than going black
        }
        session.sessionPreset = session.canSetSessionPreset(.high) ? .high : .medium
        session.commitConfiguration()
        if currentInput === input { Defaults[.cameraDeviceID] = device.uniqueID }
        applyMirror()
    }

    private func applyMirror() {
        guard let c = preview.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = Defaults[.rkCameraMirror]
    }

    // MARK: Menu (CameraAccessController)

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let current = currentInput?.device.uniqueID
        for d in AVDevices.cameras {
            let item = NSMenuItem(title: d.localizedName, action: #selector(pickDevice(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = d.uniqueID
            item.state = d.uniqueID == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let shape = NSMenuItem(title: "Shape", action: nil, keyEquivalent: "")
        let shapeMenu = NSMenu()
        for s in CameraShape.allCases {
            let i = NSMenuItem(title: s.title, action: #selector(pickShape(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = s.rawValue; i.state = Defaults[.rkCameraShape] == s ? .on : .off
            shapeMenu.addItem(i)
        }
        shape.submenu = shapeMenu
        menu.addItem(shape)
        let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for s in CameraSize.allCases {
            let i = NSMenuItem(title: s.title, action: #selector(pickSize(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = s.rawValue; i.state = Defaults[.rkCameraSize] == s ? .on : .off
            sizeMenu.addItem(i)
        }
        size.submenu = sizeMenu
        menu.addItem(size)
        let mirror = NSMenuItem(title: "Flip Camera", action: #selector(toggleMirror), keyEquivalent: "")
        mirror.target = self; mirror.state = Defaults[.rkCameraMirror] ? .on : .off
        menu.addItem(mirror)
        let full = NSMenuItem(title: isFullscreen ? "Exit Full Screen Camera" : "Full Screen Camera", action: #selector(fullscreenItem), keyEquivalent: "")
        full.target = self
        menu.addItem(full)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Hide Camera", action: #selector(hideCamera), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        return menu
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectDevice(AVCaptureDevice(uniqueID: id))
    }

    @objc private func pickShape(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = CameraShape(rawValue: raw) else { return }
        Defaults[.rkCameraShape] = s
        guard !isFullscreen else { return }
        let old = panel.frame, size = bubbleSize
        layout(frame: NSRect(x: old.maxX - size.width, y: old.minY, width: size.width, height: size.height))
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = CameraSize(rawValue: raw) else { return }
        Defaults[.rkCameraSize] = s
        height = Self.clampedHeight(s.points, area: area)
        guard !isFullscreen else { return }
        let old = panel.frame, size = bubbleSize
        layout(frame: NSRect(x: old.maxX - size.width, y: old.minY, width: size.width, height: size.height))
    }

    @objc private func toggleMirror() {
        Defaults[.rkCameraMirror].toggle()
        applyMirror()
    }

    @objc private func fullscreenItem() { toggleFullscreen() }

    @objc private func hideCamera() { onDisable?() }
}

/// Content view: drag moves the bubble, a click (no drag) toggles full screen, right-click shows the
/// menu, scroll / pinch resizes.
private final class CameraView: NSView {
    var menuProvider: (() -> NSMenu?)?
    var onScroll: ((CGFloat) -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onClick: (() -> Void)?
    private var dragStart: NSPoint?
    private var lastPoint: NSPoint = .zero
    private var dragged = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        lastPoint = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = NSEvent.mouseLocation
        if !dragged, hypot(p.x - start.x, p.y - start.y) < 3 { return }
        dragged = true
        onDrag?(CGSize(width: p.x - lastPoint.x, height: p.y - lastPoint.y))
        lastPoint = p
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard dragStart != nil, !dragged else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8))
    }

    override func magnify(with event: NSEvent) {
        onScroll?(event.magnification * bounds.height)
    }
}
