import AppKit
import QuartzCore
import ShotcraftCore

/// Window levels used by the recorder, bottom to top.
enum RecorderLevel {
    static let dim = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue)
    static let setup = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let camera = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    static let controls = NSWindow.Level.popUpMenu
    static let decoration = NSWindow.Level.screenSaver
}

/// Borderless transparent panel shared by every recorder overlay.
class RecorderPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, level: NSWindow.Level, clickThrough: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        ignoresMouseEvents = clickThrough
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
}

// MARK: - Dim

/// Dims everything outside `hole` and outlines it.
final class DimView: NSView {
    var hole: CGRect = .zero { didSet { needsDisplay = true } }  // view coordinates
    var dimAlpha: CGFloat = 0.45 { didSet { needsDisplay = true } }
    var showsBorder = true

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        let path = NSBezierPath(rect: bounds)
        path.appendRect(hole)
        path.windingRule = .evenOdd
        path.fill()
        guard showsBorder, !hole.isEmpty else { return }
        // Border drawn just outside the hole so it never ends up inside the recorded pixels.
        let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.6).setStroke()
        border.stroke()
    }
}

/// One click-through dimming window per screen while recording.
@MainActor
final class DimOverlay {
    private var windows: [RecorderPanel] = []

    init(area: CGRect, dimmed: Bool) {
        for screen in NSScreen.screens {
            guard dimmed || screen.frame.intersects(area) else { continue }
            let w = RecorderPanel(frame: screen.frame, level: RecorderLevel.dim, clickThrough: true)
            let v = DimView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.dimAlpha = dimmed ? 0.45 : 0
            v.hole = area.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            w.contentView = v
            windows.append(w)
        }
    }

    var windowNumbers: [Int] { windows.map(\.windowNumber) }

    func show() { windows.forEach { $0.orderFrontRegardless() } }
    func close() { windows.forEach { $0.orderOut(nil) }; windows.removeAll() }
}

// MARK: - Decoration window (captured into the video)

/// Transparent, click-through window over the recorded screen that hosts click ripples and the
/// keystroke HUD. It stays ordered-in for the whole recording so ScreenCaptureKit can include it.
@MainActor
final class DecorationWindow {
    let window: RecorderPanel
    let screenFrame: CGRect

    init(screen: NSScreen) {
        screenFrame = screen.frame
        window = RecorderPanel(frame: screen.frame, level: RecorderLevel.decoration, clickThrough: true)
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        window.contentView = v
    }

    var contentView: NSView { window.contentView! }
    func toLocal(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY) }
    func show() { window.orderFrontRegardless() }
    func close() { window.orderOut(nil) }
}

// MARK: - Click highlighting

/// Shows a ring under the cursor while a mouse button is down and a ripple when released.
@MainActor
final class ClickHighlighter {
    private let host: DecorationWindow
    private var monitors: [Any] = []
    private var active: CAShapeLayer?
    private let diameter: CGFloat = 44

    init(host: DecorationWindow) { self.host = host }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp,
                                           .otherMouseUp, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let type = e.type
            MainActor.assumeIsolated { self?.handle(type) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.handle(e.type)
            return e
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        active?.removeFromSuperlayer()
        active = nil
    }

    private var color: CGColor { Defaults[.clickHighlightColor].cgColor }

    private func handle(_ type: NSEvent.EventType) {
        let p = host.toLocal(NSEvent.mouseLocation)
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            active?.removeFromSuperlayer()
            let layer = CAShapeLayer()
            layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            layer.path = CGPath(ellipseIn: layer.bounds.insetBy(dx: 2, dy: 2), transform: nil)
            layer.fillColor = color.copy(alpha: (color.alpha) * 0.5)
            layer.strokeColor = color.copy(alpha: 1)
            layer.lineWidth = 3
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.position = p
            CATransaction.commit()
            host.contentView.layer?.addSublayer(layer)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.5; grow.toValue = 1; grow.duration = 0.12
            layer.add(grow, forKey: "grow")
            active = layer
        case .leftMouseDragged, .rightMouseDragged:
            CATransaction.begin(); CATransaction.setDisableActions(true)
            active?.position = p
            CATransaction.commit()
        default:
            guard let layer = active else { return }
            active = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.toValue = 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.35
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "ripple")
            CATransaction.commit()
        }
    }
}

// MARK: - Keystrokes

/// HUD at the bottom center of the recorded area showing pressed keys ("⌘⇧K", or typed text).
@MainActor
final class KeystrokeOverlay {
    private let host: DecorationWindow
    private let area: CGRect
    private let box = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var monitors: [Any] = []
    private var fadeWork: DispatchWorkItem?
    private var typing = ""
    private var showingShortcut = false

    init(host: DecorationWindow, area: CGRect) {
        self.host = host
        self.area = area
        box.material = .hudWindow
        box.appearance = NSAppearance(named: .vibrantDark)
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.alphaValue = 0
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingHead
        box.addSubview(label)
        host.contentView.addSubview(box)
    }

    func start() {
        if !Permissions.hasAccessibility { Permissions.requestAccessibility() }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            let (code, mods, chars) = (e.keyCode, e.modifierFlags, e.charactersIgnoringModifiers ?? "")
            MainActor.assumeIsolated { self?.keyDown(code: code, modifiers: mods, characters: chars) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.keyDown(code: e.keyCode, modifiers: e.modifierFlags, characters: e.charactersIgnoringModifiers ?? "")
            return e
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        fadeWork?.cancel()
        box.removeFromSuperview()
    }

    private func keyDown(code: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) {
        let mods = modifiers.intersection([.command, .control, .option, .shift])
        let name = Shortcut.keyName(UInt32(code))
        if RecordingMath.isShortcut(mods) {
            typing = ""
            showingShortcut = true
            display(RecordingMath.keystrokeLabel(modifiers: mods, key: name))
        } else {
            guard !Defaults[.rkKeystrokesShortcutsOnly] else { return }
            if showingShortcut { typing = ""; showingShortcut = false }
            let printable = characters.count == 1 && characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            if printable && name.count == 1 || code == 49 {   // 49 = space
                typing += code == 49 ? "␣" : (mods.contains(.shift) ? characters.uppercased() : characters)
            } else {
                typing += mods.contains(.shift) ? "⇧" + name : name
            }
            if typing.count > 40 { typing = String(typing.suffix(40)) }
            display(typing)
        }
    }

    private func display(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        let maxW = max(120, area.width - 40)
        let w = min(maxW, label.frame.width + 40), h = label.frame.height + 22
        let local = host.toLocal(CGPoint(x: area.midX, y: area.minY))
        box.frame = NSRect(x: local.x - w / 2, y: local.y + 40, width: w, height: h)
        label.frame = NSRect(x: 20, y: 11, width: w - 40, height: label.frame.height)
        box.alphaValue = 1
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self.box.animator().alphaValue = 0 }
                self.typing = ""
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

// MARK: - Cursor idle watcher

/// Calls `onChange(false)` after the mouse rests for `idleDelay`, `onChange(true)` when it moves again.
@MainActor
final class CursorIdleWatcher {
    private var timer: Timer?
    private var lastLocation = NSEvent.mouseLocation
    private var lastMove = Date()
    private var visible = true
    private let idleDelay: TimeInterval = 1.5
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let p = NSEvent.mouseLocation
        if p != lastLocation || NSEvent.pressedMouseButtons != 0 {
            lastLocation = p
            lastMove = Date()
            if !visible { visible = true; onChange(true) }
        } else if visible, Date().timeIntervalSince(lastMove) >= idleDelay {
            visible = false
            onChange(false)
        }
    }
}
