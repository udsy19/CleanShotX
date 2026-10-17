import AppKit
import AVFoundation
import ShotcraftCore

/// How the pre-record overlay was dismissed.
enum RecorderSetupResult {
    case cancel
    case record(RecordingKind)
    case studio
}

/// The RecorderOverlay: adjustable recording area + the pre-record panel (`RecorderSettingsView`).
@MainActor
final class RecorderSetupOverlay: NSObject {
    private let screen: NSScreen
    private let window: SetupWindow
    private let editor: AreaEditorView
    private let panel: RecorderSettingsPanel
    private var camera: CameraOverlay?
    private var onFinish: ((RecorderSetupResult) -> Void)?

    /// Global Cocoa rect.
    var area: CGRect { editor.area.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }

    init(kind: RecordingKind, area: CGRect, screen: NSScreen) {
        self.screen = screen
        window = SetupWindow(frame: screen.frame, level: RecorderLevel.setup, clickThrough: false)
        window.allowsKey = true
        editor = AreaEditorView(frame: NSRect(origin: .zero, size: screen.frame.size))
        editor.area = area.intersection(screen.frame).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        panel = RecorderSettingsPanel(primary: kind, studioAvailable: Services.studio != nil)
        super.init()
        window.contentView = editor
        editor.addSubview(panel)
        editor.onChange = { [weak self] in self?.areaChanged() }
        panel.onRecord = { [weak self] k in self?.finish(.record(k)) }
        panel.onStudio = { [weak self] in self?.finish(.studio) }
        panel.onCameraChange = { [weak self] in self?.refreshCamera() }
        panel.onResize = { [weak self] size in self?.resize(to: size) }
        panel.onAspect = { [weak self] ratio in self?.setAspect(ratio) }
        panel.onToggleFullscreen = { [weak self] in self?.toggleFullscreen() }
        window.onCancel = { [weak self] in self?.finish(.cancel) }
        window.onConfirm = { [weak self] alternate in
            guard let self else { return }
            self.finish(.record(alternate ? self.panel.alternate : self.panel.primary))
        }
    }

    func show(completion: @escaping (RecorderSetupResult) -> Void) {
        onFinish = completion
        areaChanged()
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

    private func finish(_ result: RecorderSetupResult) {
        guard let onFinish else { return }
        if case .cancel = result {} else if editor.area.width < 16 || editor.area.height < 16 { NSSound.beep(); return }
        self.onFinish = nil
        onFinish(result)
    }

    // MARK: Area

    private var localVisibleFrame: CGRect {
        screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func areaChanged() {
        let size = panel.frame.size
        let origin = RecordingMath.setupPanelOrigin(panel: size, area: editor.area, bounds: localVisibleFrame)
        panel.setFrameOrigin(origin)
        panel.update(size: editor.area.size, fullscreen: editor.area == editor.bounds)
        camera?.areaDidChange(area)
    }

    private func resize(to size: CGSize) {
        editor.aspect = nil
        editor.area = RecordingMath.resized(editor.area, to: size, within: editor.bounds)
    }

    private func setAspect(_ ratio: CGFloat?) {
        editor.aspect = ratio
        if let ratio { editor.area = RecordingMath.constrained(editor.area, toAspect: ratio, within: editor.bounds) }
    }

    private var areaBeforeFullscreen: CGRect?

    private func toggleFullscreen() {
        if editor.area == editor.bounds, let previous = areaBeforeFullscreen {
            editor.area = previous
            areaBeforeFullscreen = nil
        } else {
            areaBeforeFullscreen = editor.area
            editor.aspect = nil
            editor.area = editor.bounds
        }
    }

    // MARK: Camera

    private func refreshCamera() {
        var wants = Defaults[.recordCamera]
        if wants {
            switch Permissions.status(for: .video) {
            case .authorized: break
            case .notDetermined:
                wants = false
                Permissions.request(.video) { [weak self] ok in
                    if !ok { Defaults[.recordCamera] = false }
                    self?.panel.refresh()
                    self?.refreshCamera()
                }
            default:
                wants = false
                Defaults[.recordCamera] = false
                panel.refresh()
            }
        }
        if wants, camera == nil {
            let c = CameraOverlay(area: area)
            c.onDisable = { [weak self] in
                Defaults[.recordCamera] = false
                self?.refreshCamera()
                self?.panel.refresh()
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
    /// `true` when Option was held (the alternate recording kind).
    var onConfirm: ((Bool) -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onConfirm?(event.modifierFlags.contains(.option))
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
    /// Locked width/height ratio while resizing, nil = freeform.
    var aspect: CGFloat?
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
        let q = CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
        switch drag {
        case .none: break
        case .move(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(0, r.minX), bounds.width - r.width)
            r.origin.y = min(max(0, r.minY), bounds.height - r.height)
            area = r.integral
        case .resize(let i, let o):
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            if [0, 6, 7].contains(i) { minX = min(q.x, maxX - minSide) }
            if [2, 3, 4].contains(i) { maxX = max(q.x, minX + minSide) }
            if [0, 1, 2].contains(i) { minY = min(q.y, maxY - minSide) }
            if [4, 5, 6].contains(i) { maxY = max(q.y, minY + minSide) }
            if let aspect {
                // Width drives height, except on the top/bottom edge handles.
                if i == 1 || i == 5 {
                    let w = (maxY - minY) * aspect
                    minX = o.midX - w / 2; maxX = o.midX + w / 2
                } else {
                    let h = (maxX - minX) / aspect
                    if [0, 1, 2].contains(i) { minY = maxY - h } else if [4, 5, 6].contains(i) { maxY = minY + h }
                    else { minY = o.midY - h / 2; maxY = o.midY + h / 2 }
                }
                let r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                guard bounds.contains(r.integral) else { return }
            }
            area = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
        case .create(let start):
            var r = CGRect(x: min(start.x, q.x), y: min(start.y, q.y), width: abs(q.x - start.x), height: abs(q.y - start.y))
            if let aspect, r.width > 0 {
                r.size.height = r.width / aspect
                if q.y < start.y { r.origin.y = start.y - r.height }
                guard bounds.contains(r.integral) else { return }
            }
            area = r.integral
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .create = drag, area.width < minSide || area.height < minSide {
            // A click outside without dragging selects the whole screen.
            aspect = nil
            area = bounds
        }
        drag = .none
        window?.invalidateCursorRects(for: self)
    }
}

// MARK: - Pre-record panel (RecorderSettingsView)

/// Dark-glass styling shared by the recorder's floating panels.
enum RecorderStyle {
    static let hairline = NSColor.white.withAlphaComponent(0.08)
    static let hover = NSColor.white.withAlphaComponent(0.08)
    static let inactive = NSColor.white.withAlphaComponent(0.55)

    /// A rounded dark-glass block with a light inner hairline.
    static func glass(cornerRadius: CGFloat) -> NSVisualEffectView {
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        return fx
    }

    /// A 1-pt line view with an explicit frame (no intrinsic size, so it can never collapse a layout).
    static func line(_ frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = hairline.cgColor
        return v
    }
}

/// Three stacked glass blocks: a 2×5 settings grid, Record GIF / Record Video, and Record in Studio Mode.
private final class RecorderSettingsPanel: NSView {
    var onRecord: ((RecordingKind) -> Void)?
    var onStudio: (() -> Void)?
    var onCameraChange: (() -> Void)?
    var onResize: ((CGSize) -> Void)?
    var onAspect: ((CGFloat?) -> Void)?
    var onToggleFullscreen: (() -> Void)?

    /// Kind started by Return; Option-Return starts `alternate`.
    let primary: RecordingKind
    var alternate: RecordingKind { primary == .video ? .gif : .video }

    private static let width: CGFloat = 236
    private static let gridRow: CGFloat = 35
    private static let actionRow: CGFloat = 37
    private static let gap: CGFloat = 10

    private let settingsCell = GridCell(symbolName: "slider.vertical.3", tip: "Recording Settings", showsTick: false)
    private let fullscreenCell = GridCell(symbolName: "arrow.up.left.and.arrow.down.right", tip: "Record Full Screen", showsTick: false)
    private let ratioCell = GridCell(symbolName: "crop", tip: "Aspect Ratio and Size", showsTick: false)
    private let micCell = GridCell(symbolName: "mic", tip: "Microphone")
    private let systemAudioCell = GridCell(symbolName: "speaker.wave.2", tip: "Record System Audio")
    private let cameraCell = GridCell(symbolName: "video", tip: "Camera")
    private let clicksCell = GridCell(symbolName: "cursorarrow.rays", tip: "Highlight Clicks")
    private let keysCell = GridCell(symbolName: "command.square", tip: "Show Keystrokes")
    private let widthField = SizeField()
    private let heightField = SizeField()
    private var aspectTitle = "Freeform"

    init(primary: RecordingKind, studioAvailable: Bool) {
        self.primary = primary
        let w = Self.width
        let gridH = Self.gridRow * 2, actionsH = Self.actionRow * 2, studioH = Self.actionRow
        let height = gridH + Self.gap + actionsH + (studioAvailable ? Self.gap + studioH : 0)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: height))

        // Block 1 — settings grid (top).
        let grid = RecorderStyle.glass(cornerRadius: 16)
        grid.frame = NSRect(x: 0, y: height - gridH, width: w, height: gridH)
        addSubview(grid)
        let col = w / 5
        let top = Self.gridRow
        func place(_ v: NSView, column: Int, row: Int, span: Int = 1) {
            v.frame = NSRect(x: CGFloat(column) * col, y: row == 0 ? top : 0, width: col * CGFloat(span), height: Self.gridRow).integral
            grid.addSubview(v)
        }
        place(settingsCell, column: 0, row: 0)
        let sizeCell = NSView()
        place(sizeCell, column: 1, row: 0, span: 2)
        place(fullscreenCell, column: 3, row: 0)
        place(ratioCell, column: 4, row: 0)
        for (i, cell) in [micCell, systemAudioCell, cameraCell, clicksCell, keysCell].enumerated() { place(cell, column: i, row: 1) }
        grid.addSubview(RecorderStyle.line(NSRect(x: 0, y: Self.gridRow, width: w, height: 1)))
        for i in 1..<5 where i != 2 {   // the size field spans columns 1–2
            grid.addSubview(RecorderStyle.line(NSRect(x: (CGFloat(i) * col).rounded(), y: Self.gridRow, width: 1, height: Self.gridRow)))
        }
        for i in 1..<5 {
            grid.addSubview(RecorderStyle.line(NSRect(x: (CGFloat(i) * col).rounded(), y: 0, width: 1, height: Self.gridRow)))
        }
        buildSizeCell(sizeCell)

        // Block 2 — actions.
        let actions = RecorderStyle.glass(cornerRadius: 16)
        actions.frame = NSRect(x: 0, y: grid.frame.minY - Self.gap - actionsH, width: w, height: actionsH)
        addSubview(actions)
        let gifShortcut = primary == .gif ? "↩" : "⌥↩", videoShortcut = primary == .video ? "↩" : "⌥↩"
        let gif = ActionRow(icon: ActionRow.gifBadge(), title: "Record GIF", shortcut: gifShortcut)
        gif.frame = NSRect(x: 0, y: Self.actionRow, width: w, height: Self.actionRow)
        gif.onClick = { [weak self] in self?.onRecord?(.gif) }
        let video = ActionRow(icon: symbol("video.fill", size: 14), title: "Record Video", shortcut: videoShortcut)
        video.frame = NSRect(x: 0, y: 0, width: w, height: Self.actionRow)
        video.onClick = { [weak self] in self?.onRecord?(.video) }
        actions.addSubview(gif)
        actions.addSubview(video)
        actions.addSubview(RecorderStyle.line(NSRect(x: 0, y: Self.actionRow, width: w, height: 1)))

        // Block 3 — Studio Mode.
        if studioAvailable {
            let studio = RecorderStyle.glass(cornerRadius: studioH / 2)
            studio.frame = NSRect(x: 0, y: 0, width: w, height: studioH)
            addSubview(studio)
            let clapper = NSImage(systemSymbolName: "movieclapper.fill", accessibilityDescription: nil) != nil ? "movieclapper.fill" : "film.fill"
            let row = ActionRow(icon: symbol(clapper, size: 14), title: "Record in Studio Mode", shortcut: nil)
            row.frame = NSRect(x: 0, y: 0, width: w - 30, height: studioH)
            row.onClick = { [weak self] in self?.onStudio?() }
            studio.addSubview(row)
            let info = InfoButton(frame: NSRect(x: w - 30, y: (studioH - 16) / 2, width: 16, height: 16))
            info.onClick = { [weak info] in
                guard let info else { return }
                StudioInfoPopover.show(relativeTo: info)
            }
            studio.addSubview(info)
        }

        settingsCell.onClick = { [weak self] in self?.showSettingsMenu() }
        fullscreenCell.onClick = { [weak self] in self?.onToggleFullscreen?() }
        ratioCell.onClick = { [weak self] in self?.showRatioMenu() }
        micCell.onClick = { [weak self] in self?.showMicrophoneMenu() }
        systemAudioCell.onClick = { [weak self] in Defaults[.recordSystemAudio].toggle(); self?.refresh() }
        cameraCell.onClick = { [weak self] in self?.showCameraMenu() }
        clicksCell.onClick = { [weak self] in Defaults[.recordHighlightClicks].toggle(); self?.refresh() }
        keysCell.onClick = { [weak self] in
            Defaults[.recordShowKeystrokes].toggle()
            if Defaults[.recordShowKeystrokes], !Permissions.hasAccessibility { Permissions.requestAccessibility() }
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}   // don't let clicks fall through to the area editor

    private func buildSizeCell(_ cell: NSView) {
        let times = NSTextField(labelWithString: "×")
        times.font = .systemFont(ofSize: 12, weight: .medium)
        times.textColor = RecorderStyle.inactive
        let fieldW = (cell.frame.width - 22) / 2
        widthField.frame = NSRect(x: 4, y: 7, width: fieldW, height: 21)
        heightField.frame = NSRect(x: cell.frame.width - 4 - fieldW, y: 7, width: fieldW, height: 21)
        times.sizeToFit()
        times.frame.origin = NSPoint(x: (cell.frame.width - times.frame.width) / 2, y: (cell.frame.height - times.frame.height) / 2)
        for f in [widthField, heightField] {
            f.target = self
            f.action = #selector(sizeEdited)
            cell.addSubview(f)
        }
        widthField.toolTip = "Width"
        heightField.toolTip = "Height"
        cell.addSubview(times)
    }

    /// Reflects the current area.
    func update(size: CGSize, fullscreen: Bool) {
        let window = self.window
        if window?.firstResponder !== widthField.currentEditor() { widthField.integerValue = Int(size.width) }
        if window?.firstResponder !== heightField.currentEditor() { heightField.integerValue = Int(size.height) }
        fullscreenCell.isActive = fullscreen
        fullscreenCell.symbolName = fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        fullscreenCell.toolTip = fullscreen ? "Restore Previous Area" : "Record Full Screen"
    }

    @objc private func sizeEdited() {
        onResize?(CGSize(width: max(16, widthField.integerValue), height: max(16, heightField.integerValue)))
        window?.makeFirstResponder(superview)
    }

    func refresh() {
        let mic = Defaults[.recordMicrophone]
        micCell.isActive = mic
        micCell.symbolName = mic ? "mic.fill" : "mic"
        micCell.toolTip = mic ? "Microphone: \(AVDevices.selectedMicrophone?.localizedName ?? "Default")" : "Do Not Record Microphone"
        systemAudioCell.isActive = Defaults[.recordSystemAudio]
        systemAudioCell.symbolName = Defaults[.recordSystemAudio] ? "speaker.wave.2.fill" : "speaker.wave.2"
        let cam = Defaults[.recordCamera]
        cameraCell.isActive = cam
        cameraCell.symbolName = cam ? "video.fill" : "video"
        cameraCell.toolTip = cam ? "Camera: \(AVDevices.selectedCamera?.localizedName ?? "Default")" : "Do Not Record Camera"
        clicksCell.isActive = Defaults[.recordHighlightClicks]
        keysCell.isActive = Defaults[.recordShowKeystrokes]
        ratioCell.toolTip = "Aspect Ratio: \(aspectTitle)"
    }

    private func popUp(_ menu: NSMenu, below view: NSView) {
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }

    // MARK: Ratio

    private func showRatioMenu() {
        let menu = NSMenu()
        for (title, ratio) in [("Freeform", 0.0), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1.0), ("9:16", 9.0 / 16)] {
            let item = NSMenuItem(title: title, action: #selector(pickRatio(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ratio
            item.state = aspectTitle == title ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (w, h) in [(640, 480), (1280, 720), (1920, 1080)] {
            let item = NSMenuItem(title: "\(w) × \(h)", action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSValue(size: NSSize(width: w, height: h))
            menu.addItem(item)
        }
        popUp(menu, below: ratioCell)
    }

    @objc private func pickRatio(_ sender: NSMenuItem) {
        let ratio = sender.representedObject as? Double ?? 0
        aspectTitle = sender.title
        ratioCell.isActive = ratio > 0
        onAspect?(ratio > 0 ? CGFloat(ratio) : nil)
        refresh()
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let size = (sender.representedObject as? NSValue)?.sizeValue else { return }
        aspectTitle = "Freeform"
        ratioCell.isActive = false
        onResize?(size)
        refresh()
    }

    // MARK: Devices

    private func showMicrophoneMenu() {
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
        popUp(menu, below: micCell)
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

    private func showCameraMenu() {
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
        popUp(menu, below: cameraCell)
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

    // MARK: Settings

    private func showSettingsMenu() {
        let menu = NSMenu()
        func toggle(_ title: String, _ key: Defaults.Key<Bool>, indent: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = Defaults[key] ? .on : .off
            item.indentationLevel = indent ? 1 : 0
            menu.addItem(item)
        }
        toggle("Show Cursor", .recordShowCursor)
        toggle("Hide Cursor When Not Moving", .recordHideCursorWhenNotMoving)
        if Defaults[.recordShowKeystrokes] { toggle("Show Only Command Keys", .rkKeystrokesShortcutsOnly) }
        if Defaults[.recordHighlightClicks] {
            let styleItem = NSMenuItem(title: "Click Style", action: nil, keyEquivalent: "")
            let styleMenu = NSMenu()
            for style in ClickStyle.allCases {
                let i = NSMenuItem(title: style.title, action: #selector(pickClickStyle(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = style.rawValue; i.state = Defaults[.rkClickStyle] == style ? .on : .off
                styleMenu.addItem(i)
            }
            styleItem.submenu = styleMenu
            menu.addItem(styleItem)
        }
        menu.addItem(.separator())
        toggle("Dim Screen While Recording", .recordDimScreen)
        toggle("Show Controls While Recording", .recordShowControls)
        toggle("Show Countdown", .recordCountdown)
        toggle("Record Audio in Mono", .recordAudioMono)
        toggle("Scale Retina Videos to 1x", .scaleRetinaVideosTo1x)
        menu.addItem(.separator())

        func fpsMenu(_ title: String, values: [Int], key: Defaults.Key<Int>) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for v in values {
                let i = NSMenuItem(title: "\(v) FPS", action: #selector(pickFPS(_:)), keyEquivalent: "")
                i.target = self; i.tag = v; i.representedObject = key; i.state = Defaults[key] == v ? .on : .off
                sub.addItem(i)
            }
            item.submenu = sub
            menu.addItem(item)
        }
        fpsMenu("Video Frame Rate", values: [15, 24, 30, 60], key: .videoFPS)
        fpsMenu("GIF Frame Rate", values: [5, 10, 15, 20, 25, 30], key: .gifFPS)

        let qItem = NSMenuItem(title: "Video Quality", action: nil, keyEquivalent: "")
        let qMenu = NSMenu()
        for q in VideoQuality.allCases {
            let i = NSMenuItem(title: q.displayName, action: #selector(pickQuality(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = q.rawValue; i.state = Defaults[.videoQuality] == q ? .on : .off
            qMenu.addItem(i)
        }
        qItem.submenu = qMenu
        menu.addItem(qItem)
        popUp(menu, below: settingsCell)
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Defaults.Key<Bool> else { return }
        Defaults[key].toggle()
        refresh()
    }

    @objc private func pickClickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = ClickStyle(rawValue: raw) else { return }
        Defaults[.rkClickStyle] = style
    }

    @objc private func pickFPS(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Defaults.Key<Int> else { return }
        Defaults[key] = sender.tag
    }

    @objc private func pickQuality(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let q = VideoQuality(rawValue: raw) else { return }
        Defaults[.videoQuality] = q
    }
}

// MARK: - Panel pieces

/// One square of the settings grid: a white glyph, bright with a small tick under it when active.
private final class GridCell: NSView {
    var onClick: (() -> Void)?
    var symbolName: String { didSet { if symbolName != oldValue { icon.image = symbol(symbolName, size: 15) } } }
    var isActive = false { didSet { updateLook() } }

    private let icon = NSImageView()
    private let tick = NSImageView()
    private let showsTick: Bool
    private var hovering = false { didSet { updateLook() } }

    init(symbolName: String, tip: String, showsTick: Bool = true) {
        self.symbolName = symbolName
        self.showsTick = showsTick
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = symbol(symbolName, size: 15)
        icon.imageScaling = .scaleNone
        tick.image = symbol("checkmark", size: 7, weight: .heavy)
        tick.imageScaling = .scaleNone
        tick.contentTintColor = .white
        addSubview(icon)
        addSubview(tick)
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip)
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let tickSpace: CGFloat = showsTick ? 5 : 0
        icon.frame = NSRect(x: 0, y: tickSpace, width: bounds.width, height: bounds.height - tickSpace)
        tick.frame = NSRect(x: 0, y: 3, width: bounds.width, height: 9)
    }

    private func updateLook() {
        icon.contentTintColor = isActive || hovering ? .white : RecorderStyle.inactive
        tick.isHidden = !(showsTick && isActive)
        layer?.backgroundColor = hovering ? RecorderStyle.hover.cgColor : nil
        setAccessibilityValue(isActive ? "On" : "Off")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// Numeric W / H field on a dark inset.
private final class SizeField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        textColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = 5
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 16
        f.maximum = 16_384
        formatter = f
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// "Record GIF ⌥↩"-style row with a leading icon, title and right-aligned shortcut.
private final class ActionRow: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { layer?.backgroundColor = hovering ? RecorderStyle.hover.cgColor : nil } }

    init(icon: NSImage, title: String, shortcut: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        let iconView = NSImageView(image: icon)
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleNone
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        // Rows without a shortcut (Studio Mode) give the title the full width instead of a trailing spacer.
        let views: [NSView] = [iconView, titleLabel] + (shortcut.map { s -> [NSView] in
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13, weight: .regular)
            l.textColor = NSColor.white.withAlphaComponent(0.5)
            return [NSView(), l]
        } ?? [])
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: shortcut == nil ? 4 : 14)
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// White rounded badge with dark "GIF" text.
    static func gifBadge() -> NSImage {
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size, flipped: false) { r in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5).fill()
            let text = NSAttributedString(string: "GIF", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .heavy),
                .foregroundColor: NSColor.black.withAlphaComponent(0.85),
            ])
            let s = text.size()
            text.draw(at: NSPoint(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The grey "?" circle next to "Record in Studio Mode".
private final class InfoButton: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "What is Studio Mode?"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("What is Studio Mode?")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let q = NSAttributedString(string: "?", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ])
        let s = q.size()
        q.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// "What is Studio Mode?" card, shown in a transient popover.
private final class StudioInfoPopover: NSViewController {
    private weak var popover: NSPopover?

    static func show(relativeTo view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = StudioInfoPopover()
        vc.popover = popover
        popover.contentViewController = vc
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    override func loadView() {
        let name = NSImage(systemSymbolName: "movieclapper.fill", accessibilityDescription: nil) != nil ? "movieclapper.fill" : "film.fill"
        let icon = NSImageView(image: symbol(name, size: 26, weight: .semibold))
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "What is Studio Mode?")
        title.font = .systemFont(ofSize: 17, weight: .bold)
        let body = NSTextField(wrappingLabelWithString:
            "Studio Mode records your screen as an editable project. After recording you can add smooth zooms, "
            + "style the cursor and click effects, and fine-tune the rest before exporting a polished video.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 290
        body.widthAnchor.constraint(equalToConstant: 290).isActive = true
        let ok = NSButton(title: "Awesome!", target: self, action: #selector(dismissCard))
        ok.bezelStyle = .push
        ok.controlSize = .large
        ok.keyEquivalent = "\r"
        let stack = NSStackView(views: [icon, title, body, ok])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.setCustomSpacing(18, after: body)
        view = stack
    }

    @objc private func dismissCard() { popover?.performClose(nil) }
}
