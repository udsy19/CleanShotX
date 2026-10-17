import AppKit
import AVFoundation
import ShotcraftCore

/// The RecorderOverlay: adjustable recording area + setup bar (mode, audio, camera, options, start).
@MainActor
final class RecorderSetupOverlay: NSObject {
    private(set) var kind: RecordingKind
    private let screen: NSScreen
    private let window: SetupWindow
    private let editor: AreaEditorView
    private let bar: RecorderSetupBar
    private var camera: CameraOverlay?
    private var onFinish: ((_ start: Bool) -> Void)?

    /// Global Cocoa rect.
    var area: CGRect { editor.area.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }

    init(kind: RecordingKind, area: CGRect, screen: NSScreen) {
        self.kind = kind
        self.screen = screen
        window = SetupWindow(frame: screen.frame, level: RecorderLevel.setup, clickThrough: false)
        window.allowsKey = true
        editor = AreaEditorView(frame: NSRect(origin: .zero, size: screen.frame.size))
        editor.area = area.intersection(screen.frame).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        bar = RecorderSetupBar(kind: kind)
        super.init()
        window.contentView = editor
        editor.addSubview(bar)
        editor.onChange = { [weak self] in self?.layoutBar() }
        bar.onKindChange = { [weak self] k in self?.kind = k; self?.refreshCamera() }
        bar.onStart = { [weak self] in self?.finish(true) }
        bar.onCancel = { [weak self] in self?.finish(false) }
        bar.onCameraChange = { [weak self] in self?.refreshCamera() }
        window.onCancel = { [weak self] in self?.finish(false) }
        window.onConfirm = { [weak self] in self?.finish(true) }
    }

    func show(completion: @escaping (_ start: Bool) -> Void) {
        onFinish = completion
        layoutBar()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        refreshCamera()
    }

    /// Hands the live camera bubble over to the recording session.
    func takeCamera() -> CameraOverlay? {
        defer { camera = nil }
        return camera
    }

    func close() {
        window.orderOut(nil)
        camera?.close()
        camera = nil
    }

    private func finish(_ start: Bool) {
        guard let onFinish else { return }
        if start && (editor.area.width < 16 || editor.area.height < 16) { NSSound.beep(); return }
        self.onFinish = nil
        onFinish(start)
    }

    private func layoutBar() {
        let size = bar.fittingSize
        let globalArea = area
        let frame = RecordingControlsPanel.placement(for: size, area: globalArea, screen: screen)
        bar.frame = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        bar.dimensions = RecordingMath.evenPixelSize(points: globalArea.size, scale: 1)
    }

    private func refreshCamera() {
        var wants = kind == .video && Defaults[.recordCamera]
        if wants {
            switch Permissions.status(for: .video) {
            case .authorized: break
            case .notDetermined:
                wants = false
                Permissions.request(.video) { [weak self] ok in
                    if !ok { Defaults[.recordCamera] = false; self?.bar.refresh() }
                    self?.refreshCamera()
                }
            default:
                wants = false
                Defaults[.recordCamera] = false
                bar.refresh()
            }
        }
        if wants, camera == nil {
            let c = CameraOverlay(area: area)
            c.onDisable = { [weak self] in
                Defaults[.recordCamera] = false
                self?.refreshCamera()
                self?.bar.refresh()
            }
            camera = c
            c.show()
        } else if !wants, let c = camera {
            c.close()
            camera = nil
        }
    }
}

// MARK: - Window

private final class SetupWindow: RecorderPanel {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onConfirm?()
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Area editor

/// Dims outside the area; drag inside to move, drag a handle to resize, drag outside to draw a new area.
private final class AreaEditorView: NSView {
    var area: CGRect = .zero {
        didSet { needsDisplay = true; window?.invalidateCursorRects(for: self); onChange?() }
    }
    var onChange: (() -> Void)?

    private enum Drag { case none, move(CGPoint, CGRect), resize(Int, CGRect), create(CGPoint) }
    private var drag: Drag = .none
    private let handleSize: CGFloat = 10
    private let minSide: CGFloat = 32

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    /// Handle centers clockwise from bottom-left: 0 BL, 1 B, 2 BR, 3 R, 4 TR, 5 T, 6 TL, 7 L.
    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        let dim = NSBezierPath(rect: bounds)
        dim.appendRect(area)
        dim.windingRule = .evenOdd
        dim.fill()
        let border = NSBezierPath(rect: area.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        let dash: [CGFloat] = [6, 4]
        border.setLineDash(dash, count: 2, phase: 0)
        NSColor.white.setStroke()
        border.stroke()
        for c in handles(area) {
            let r = CGRect(x: c.x - handleSize / 2, y: c.y - handleSize / 2, width: handleSize, height: handleSize)
            let p = NSBezierPath(ovalIn: r)
            NSColor.white.setFill(); p.fill()
            NSColor.black.withAlphaComponent(0.3).setStroke(); p.lineWidth = 1; p.stroke()
        }
    }

    override func resetCursorRects() {
        addCursorRect(area.insetBy(dx: handleSize, dy: handleSize), cursor: .openHand)
        for (i, c) in handles(area).enumerated() {
            let r = CGRect(x: c.x - handleSize, y: c.y - handleSize, width: handleSize * 2, height: handleSize * 2)
            let cursor: NSCursor
            if #available(macOS 15, *) {
                let directions: [NSCursor.FrameResizePosition] = [.bottomLeft, .bottom, .bottomRight, .right, .topRight, .top, .topLeft, .left]
                cursor = .frameResize(position: directions[i], directions: .all)
            } else {
                cursor = i % 4 == 1 ? .resizeUpDown : (i % 4 == 3 ? .resizeLeftRight : .crosshair)
            }
            addCursorRect(r, cursor: cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = handles(area).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= handleSize }) {
            drag = .resize(i, area)
        } else if area.contains(p) {
            drag = .move(p, area)
            NSCursor.closedHand.set()
        } else {
            drag = .create(p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none: break
        case .move(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(0, r.minX), bounds.width - r.width)
            r.origin.y = min(max(0, r.minY), bounds.height - r.height)
            area = r.integral
        case .resize(let i, let o):
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            let q = CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
            if [0, 6, 7].contains(i) { minX = min(q.x, maxX - minSide) }
            if [2, 3, 4].contains(i) { maxX = max(q.x, minX + minSide) }
            if [0, 1, 2].contains(i) { minY = min(q.y, maxY - minSide) }
            if [4, 5, 6].contains(i) { maxY = max(q.y, minY + minSide) }
            area = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
        case .create(let start):
            let q = CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
            area = CGRect(x: min(start.x, q.x), y: min(start.y, q.y), width: abs(q.x - start.x), height: abs(q.y - start.y)).integral
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .create = drag, area.width < minSide || area.height < minSide {
            // A click outside without dragging selects the whole screen.
            area = bounds
        }
        drag = .none
        window?.invalidateCursorRects(for: self)
    }
}

// MARK: - Setup bar (RecorderSettingsView)

private final class RecorderSetupBar: NSVisualEffectView {
    var onKindChange: ((RecordingKind) -> Void)?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCameraChange: (() -> Void)?
    var dimensions: (width: Int, height: Int) = (0, 0) {
        didSet { sizeLabel.stringValue = "\(dimensions.width) × \(dimensions.height)" }
    }

    private var kind: RecordingKind
    private let modeControl = NSSegmentedControl(labels: ["Video", "GIF"], trackingMode: .selectOne, target: nil, action: nil)
    private let micButton = NSButton()
    private let audioButton = NSButton()
    private let cameraButton = NSButton()
    private let settingsButton = NSButton()
    private let startButton = NSButton()
    private let sizeLabel = NSTextField(labelWithString: "")
    private var audioGroup: [NSView] = []

    init(kind: RecordingKind) {
        self.kind = kind
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let close = NSButton()
        style(close, "xmark", "Cancel (Esc)", #selector(cancelClicked))
        modeControl.selectedSegment = kind == .video ? 0 : 1
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .capsule
        style(micButton, "mic", "Record microphone", #selector(micClicked))
        style(audioButton, "speaker.wave.2", "Record system audio", #selector(audioClicked))
        style(cameraButton, "video", "Record camera", #selector(cameraClicked))
        style(settingsButton, "gearshape", "Recording settings", #selector(settingsClicked))
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor

        startButton.bezelStyle = .push
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        startButton.bezelColor = .systemRed
        startButton.image = symbol("record.circle", size: 14)
        startButton.imagePosition = .imageLeading
        startButton.target = self
        startButton.action = #selector(startClicked)

        let sep = { () -> NSBox in let b = NSBox(); b.boxType = .separator; b.heightAnchor.constraint(equalToConstant: 20).isActive = true; return b }
        let audioSep = sep()
        audioGroup = [micButton, audioButton, cameraButton, audioSep]
        let stack = NSStackView(views: [close, sep(), modeControl, sep(), micButton, audioButton, cameraButton, audioSep,
                                        settingsButton, sizeLabel, startButton])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}   // don't let clicks fall through to the area editor

    private func style(_ b: NSButton, _ icon: String, _ tip: String, _ sel: Selector) {
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.image = symbol(icon, size: 15)
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.target = self
        b.action = sel
    }

    func refresh() {
        let isVideo = kind == .video
        audioGroup.forEach { $0.isHidden = !isVideo }
        startButton.title = isVideo ? "Start Video Recording" : "Start GIF Recording"
        let mic = Defaults[.recordMicrophone]
        micButton.image = symbol(mic ? "mic.fill" : "mic.slash", size: 15)
        micButton.contentTintColor = mic ? .controlAccentColor : .secondaryLabelColor
        micButton.toolTip = mic ? "Microphone: \(AVDevices.selectedMicrophone?.localizedName ?? "Default")" : "Do Not Record Microphone"
        let sys = Defaults[.recordSystemAudio]
        audioButton.image = symbol(sys ? "speaker.wave.2.fill" : "speaker.slash", size: 15)
        audioButton.contentTintColor = sys ? .controlAccentColor : .secondaryLabelColor
        let cam = Defaults[.recordCamera]
        cameraButton.image = symbol(cam ? "video.fill" : "video.slash", size: 15)
        cameraButton.contentTintColor = cam ? .controlAccentColor : .secondaryLabelColor
        superview?.needsLayout = true
        (superview as? AreaEditorView)?.onChange?()
    }

    // MARK: Actions

    @objc private func cancelClicked() { onCancel?() }
    @objc private func startClicked() { onStart?() }

    @objc private func modeChanged() {
        kind = modeControl.selectedSegment == 0 ? .video : .gif
        refresh()
        onKindChange?(kind)
    }

    @objc private func audioClicked() {
        Defaults[.recordSystemAudio].toggle()
        refresh()
    }

    @objc private func micClicked() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let selected = Defaults[.recordMicrophone] ? AVDevices.selectedMicrophone?.uniqueID : nil
        for d in AVDevices.microphones {
            let item = NSMenuItem(title: d.localizedName, action: #selector(pickMic(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = d.uniqueID
            item.state = d.uniqueID == selected ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let none = NSMenuItem(title: "Do Not Record Microphone", action: #selector(pickMic(_:)), keyEquivalent: "")
        none.target = self
        none.state = selected == nil ? .on : .off
        menu.addItem(none)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: micButton.bounds.height + 4), in: micButton)
    }

    @objc private func pickMic(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            Defaults[.recordMicrophone] = false
            refresh(); return
        }
        DeviceAccess.ensure(.audio) { [weak self] ok in
            Defaults[.recordMicrophone] = ok
            if ok { Defaults[.microphoneDeviceID] = id }
            self?.refresh()
        }
    }

    @objc private func cameraClicked() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let selected = Defaults[.recordCamera] ? AVDevices.selectedCamera?.uniqueID : nil
        for d in AVDevices.cameras {
            let item = NSMenuItem(title: d.localizedName, action: #selector(pickCamera(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = d.uniqueID
            item.state = d.uniqueID == selected ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let none = NSMenuItem(title: "Do Not Record Camera", action: #selector(pickCamera(_:)), keyEquivalent: "")
        none.target = self
        none.state = selected == nil ? .on : .off
        menu.addItem(none)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: cameraButton.bounds.height + 4), in: cameraButton)
    }

    @objc private func pickCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            Defaults[.recordCamera] = false
            refresh(); onCameraChange?(); return
        }
        DeviceAccess.ensure(.video) { [weak self] ok in
            if ok {
                // Re-create the bubble so it picks up the new device.
                if Defaults[.recordCamera] && Defaults[.cameraDeviceID] != id {
                    Defaults[.recordCamera] = false
                    self?.onCameraChange?()
                }
                Defaults[.cameraDeviceID] = id
            }
            Defaults[.recordCamera] = ok
            self?.refresh()
            self?.onCameraChange?()
        }
    }

    @objc private func settingsClicked() {
        let menu = NSMenu()
        func toggle(_ title: String, _ key: Defaults.Key<Bool>) {
            let item = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = Defaults[key] ? .on : .off
            menu.addItem(item)
        }
        toggle("Show Cursor", .recordShowCursor)
        toggle("Highlight Clicks", .recordHighlightClicks)
        toggle("Show Keystrokes", .recordShowKeystrokes)
        if kind == .video && Defaults[.recordShowKeystrokes] { toggle("    Shortcuts Only", .rkKeystrokesShortcutsOnly) }
        toggle("Hide Cursor When Not Moving", .recordHideCursorWhenNotMoving)
        menu.addItem(.separator())
        toggle("Dim Screen While Recording", .recordDimScreen)
        toggle("Show Controls While Recording", .recordShowControls)
        toggle("Show Countdown", .recordCountdown)
        if kind == .video {
            toggle("Record Audio in Mono", .recordAudioMono)
            toggle("Scale Retina Videos to 1x", .scaleRetinaVideosTo1x)
        }
        menu.addItem(.separator())

        let fpsValues = kind == .video ? [15, 24, 30, 60] : [5, 10, 15, 20, 25, 30]
        let fpsKey: Defaults.Key<Int> = kind == .video ? .videoFPS : .gifFPS
        let fpsItem = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for v in fpsValues {
            let i = NSMenuItem(title: "\(v) FPS", action: #selector(pickFPS(_:)), keyEquivalent: "")
            i.target = self; i.tag = v; i.state = Defaults[fpsKey] == v ? .on : .off
            fpsMenu.addItem(i)
        }
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)

        if kind == .video {
            let qItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
            let qMenu = NSMenu()
            for q in VideoQuality.allCases {
                let i = NSMenuItem(title: q.displayName, action: #selector(pickQuality(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = q.rawValue; i.state = Defaults[.videoQuality] == q ? .on : .off
                qMenu.addItem(i)
            }
            qItem.submenu = qMenu
            menu.addItem(qItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: settingsButton.bounds.height + 4), in: settingsButton)
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Defaults.Key<Bool> else { return }
        Defaults[key].toggle()
        if key === Defaults.Keys.recordShowKeystrokes, Defaults[key], !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
        refresh()
    }

    @objc private func pickFPS(_ sender: NSMenuItem) {
        if kind == .video { Defaults[.videoFPS] = sender.tag } else { Defaults[.gifFPS] = sender.tag }
    }

    @objc private func pickQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let q = VideoQuality(rawValue: raw) else { return }
        Defaults[.videoQuality] = q
    }
}
