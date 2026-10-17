import AppKit
import QuartzCore
import SuperScreenshotCore

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

/// Dims everything outside `hole` and outlines it: a faint white hairline over the dim, or a red frame
/// when the screen isn't dimmed ("Dim screen while recording" off).
final class DimView: NSView {
    var hole: CGRect = .zero { didSet { needsDisplay = true } }  // view coordinates
    var dimmed = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if dimmed {
            NSColor.black.withAlphaComponent(0.45).setFill()
            let path = NSBezierPath(rect: bounds)
            path.appendRect(hole)
            path.windingRule = .evenOdd
            path.fill()
        }
        guard !hole.isEmpty, hole != bounds else { return }
        // Drawn just outside the hole so it never ends up inside the recorded pixels.
        let width: CGFloat = dimmed ? 1 : 2
        let border = NSBezierPath(rect: hole.insetBy(dx: -width / 2 - 1, dy: -width / 2 - 1))
        border.lineWidth = width
        (dimmed ? NSColor.white.withAlphaComponent(0.6) : NSColor.systemRed).setStroke()
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
            v.dimmed = dimmed
            v.hole = area.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            w.contentView = v
            windows.append(w)
        }
    }

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

/// While a button is down: a ring around a solid dot (Outline) or a translucent disc (Filled) that pops in
/// from 60 % and follows drags; on release it fades out.
@MainActor
final class ClickHighlighter {
    private let host: DecorationWindow
    private var monitors: [Any] = []
    private var active: CALayer?
    private let diameter: CGFloat = 36
    private let style = Defaults[.rkClickStyle]
    private let color = Defaults[.clickHighlightColor].cgColor

    init(host: DecorationWindow) { self.host = host }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp,
                                           .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
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

    private func makeLayer() -> CALayer {
        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let opaque = color.copy(alpha: 1) ?? color
        switch style {
        case .outline:
            // Light ring (the colour mixed 45 % toward white, 70 % opaque) around a 12-pt solid dot.
            let ring = CAShapeLayer()
            ring.frame = root.bounds
            ring.path = CGPath(ellipseIn: root.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = (NSColor(cgColor: opaque)?.blended(withFraction: 0.45, of: .white) ?? .white)
                .withAlphaComponent(0.7).cgColor
            ring.lineWidth = 3
            let dot = CAShapeLayer()
            dot.frame = root.bounds
            dot.path = CGPath(ellipseIn: root.bounds.insetBy(dx: (diameter - 12) / 2, dy: (diameter - 12) / 2), transform: nil)
            dot.fillColor = opaque
            root.addSublayer(ring)
            root.addSublayer(dot)
        case .filled:
            let disc = CAShapeLayer()
            disc.frame = root.bounds
            disc.path = CGPath(ellipseIn: root.bounds, transform: nil)
            disc.fillColor = opaque.copy(alpha: 0.4)
            root.addSublayer(disc)
        }
        return root
    }

    private func handle(_ type: NSEvent.EventType) {
        let p = host.toLocal(NSEvent.mouseLocation)
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            active?.removeFromSuperlayer()
            let layer = makeLayer()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.position = p
            CATransaction.commit()
            host.contentView.layer?.addSublayer(layer)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.6; grow.toValue = 1; grow.duration = 0.15
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(grow, forKey: "grow")
            active = layer
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            CATransaction.begin(); CATransaction.setDisableActions(true)
            active?.position = p
            CATransaction.commit()
        default:
            guard let layer = active else { return }
            active = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0
            fade.duration = 0.35
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }
}

// MARK: - Keystrokes

/// Dark rounded HUD 60 pt above the bottom centre of the recorded area showing pressed keys ("⌘⇧K",
/// or typed text when "Show only command keys" is off). Fades after a second idle; repeats bump.
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
    private let shortcutsOnly = Defaults[.rkKeystrokesShortcutsOnly]

    private static let height: CGFloat = 52
    private static let padding: CGFloat = 18

    init(host: DecorationWindow, area: CGRect) {
        self.host = host
        self.area = area
        box.material = .hudWindow
        box.appearance = NSAppearance(named: .darkAqua)
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = NSColor(red: 30 / 255, green: 30 / 255, blue: 40 / 255, alpha: 0.75).cgColor
        box.alphaValue = 0
        let base = NSFont.systemFont(ofSize: 28, weight: .semibold)
        label.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 28) } ?? base
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingHead
        box.addSubview(label)
        host.contentView.addSubview(box)
    }

    func start() {
        if !Permissions.hasAccessibility { Permissions.requestAccessibility() }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            let (code, mods, chars, isRepeat) = (e.keyCode, e.modifierFlags, e.charactersIgnoringModifiers ?? "", e.isARepeat)
            MainActor.assumeIsolated { self?.keyDown(code: code, modifiers: mods, characters: chars, isRepeat: isRepeat) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.keyDown(code: e.keyCode, modifiers: e.modifierFlags, characters: e.charactersIgnoringModifiers ?? "", isRepeat: e.isARepeat)
            return e
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        fadeWork?.cancel()
        fadeWork = nil
        box.removeFromSuperview()
    }

    private func keyDown(code: UInt16, modifiers: NSEvent.ModifierFlags, characters: String, isRepeat: Bool) {
        let mods = modifiers.intersection([.command, .control, .option, .shift])
        let name = Shortcut.keyName(UInt32(code))
        if RecordingMath.isShortcut(mods) {
            let text = RecordingMath.keystrokeLabel(modifiers: mods, key: name)
            let same = showingShortcut && label.stringValue == text && box.alphaValue > 0
            typing = ""
            showingShortcut = true
            display(text, bump: same && !isRepeat)
        } else {
            guard !shortcutsOnly else { return }
            if showingShortcut { typing = ""; showingShortcut = false }
            let printable = characters.count == 1 && characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            if printable && name.count == 1 || code == 49 {   // 49 = space
                typing += code == 49 ? "␣" : (mods.contains(.shift) ? characters.uppercased() : characters)
            } else {
                typing += mods.contains(.shift) ? "⇧" + name : name
            }
            if typing.count > 40 { typing = String(typing.suffix(40)) }
            display(typing, bump: false)
        }
    }

    private func display(_ text: String, bump: Bool) {
        label.stringValue = text
        label.sizeToFit()
        let maxW = max(120, area.width - 40)
        let w = min(maxW, max(Self.height, label.frame.width + Self.padding * 2)), h = Self.height
        let local = host.toLocal(CGPoint(x: area.midX, y: area.minY))
        box.frame = NSRect(x: (local.x - w / 2).rounded(), y: local.y + 60, width: w, height: h)
        label.frame = NSRect(x: Self.padding, y: ((h - label.frame.height) / 2).rounded(), width: w - Self.padding * 2, height: label.frame.height)
        box.layer?.removeAnimation(forKey: "fade")
        box.alphaValue = 1
        if bump, let layer = box.layer {
            // Scale around the centre: the layer's anchor is its bottom-left corner.
            let pop = CAKeyframeAnimation(keyPath: "transform")
            let c = CGPoint(x: w / 2, y: h / 2)
            func scaled(_ s: CGFloat) -> CATransform3D {
                CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0), CATransform3DMakeScale(s, s, 1)),
                                    CATransform3DMakeTranslation(c.x, c.y, 0))
            }
            pop.values = [scaled(1), scaled(1.08), scaled(1)].map { NSValue(caTransform3D: $0) }
            pop.duration = 0.18
            layer.add(pop, forKey: "bump")
        }
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self.box.animator().alphaValue = 0 }
                self.typing = ""
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
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
