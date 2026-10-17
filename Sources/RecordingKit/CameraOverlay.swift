import AppKit
import AVFoundation
import ShotcraftCore

/// Floating webcam bubble (circle or rounded rectangle) that is recorded together with the screen.
/// Drag to move; right-click for device / shape / size / mirror; scroll or pinch to resize.
@MainActor
final class CameraOverlay: NSObject {
    private let panel: RecorderPanel
    private let container = CameraView()
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    private var currentInput: AVCaptureDeviceInput?
    private var side: CGFloat
    private let sessionQueue = DispatchQueue(label: "shotcraft.recording.camera")

    var windowNumber: Int { panel.windowNumber }
    var onDisable: (() -> Void)?

    /// Places the bubble in the bottom-left corner inside `area`.
    init(area: CGRect) {
        side = Defaults[.rkCameraSize].points
        side = min(side, max(80, min(area.width, area.height) * 0.6))
        let frame = NSRect(x: area.minX + 16, y: area.minY + 16, width: side, height: side)
        panel = RecorderPanel(frame: frame, level: RecorderLevel.camera, clickThrough: false)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        preview.videoGravity = .resizeAspectFill
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.addSublayer(preview)
        container.menuProvider = { [weak self] in self?.makeMenu() }
        container.onScroll = { [weak self] delta in self?.resize(by: delta) }
        panel.contentView = container
        applyShape()
        selectDevice(AVDevices.selectedCamera)
    }

    func show() {
        panel.orderFrontRegardless()
        let s = UncheckedBox(session)
        sessionQueue.async { if !s.value.isRunning { s.value.startRunning() } }
    }

    func close() {
        panel.orderOut(nil)
        let s = UncheckedBox(session)
        sessionQueue.async { s.value.stopRunning() }
    }

    // MARK: Configuration

    private func selectDevice(_ device: AVCaptureDevice?) {
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if let currentInput { session.removeInput(currentInput) }
        if session.canAddInput(input) { session.addInput(input); currentInput = input }
        session.sessionPreset = session.canSetSessionPreset(.high) ? .high : .medium
        session.commitConfiguration()
        Defaults[.cameraDeviceID] = device.uniqueID
        applyMirror()
    }

    private func applyMirror() {
        guard let c = preview.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = Defaults[.rkCameraMirror]
    }

    private func applyShape() {
        var f = panel.frame
        f.size = CGSize(width: side, height: side)
        panel.setFrame(f, display: true)
        container.frame = NSRect(origin: .zero, size: f.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = container.bounds
        container.layer?.cornerRadius = Defaults[.rkCameraShape] == .circle ? side / 2 : side * 0.14
        container.layer?.borderWidth = 2
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        CATransaction.commit()
        panel.invalidateShadow()
    }

    private func resize(by delta: CGFloat) {
        let screen = panel.screen?.frame.size ?? CGSize(width: 1440, height: 900)
        side = min(min(screen.width, screen.height) * 0.6, max(80, side + delta))
        applyShape()
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
        let mirror = NSMenuItem(title: "Mirror Camera", action: #selector(toggleMirror), keyEquivalent: "")
        mirror.target = self; mirror.state = Defaults[.rkCameraMirror] ? .on : .off
        menu.addItem(mirror)
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
        applyShape()
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = CameraSize(rawValue: raw) else { return }
        Defaults[.rkCameraSize] = s
        side = s.points
        applyShape()
    }

    @objc private func toggleMirror() {
        Defaults[.rkCameraMirror].toggle()
        applyMirror()
    }

    @objc private func hideCamera() { onDisable?() }
}

/// Content view: drags move the window, right-click shows the menu, scroll resizes.
private final class CameraView: NSView {
    var menuProvider: (() -> NSMenu?)?
    var onScroll: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8))
    }

    override func magnify(with event: NSEvent) {
        onScroll?(event.magnification * bounds.width)
    }
}
