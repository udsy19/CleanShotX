import AppKit
import Carbon.HIToolbox
import ShotcraftCore

/// Self-Timer countdown (CleanShot: `SelfTimerOverlay` – `seconds`, `secondsLabel`, `cancelButton`,
/// `intervalTimer`; same look as `CountDownOverlay`). A black disc with the remaining seconds and a progress
/// arc sits in the middle of the area, the area is outlined, it ticks every second and then fires.
/// The panels never take keyboard focus so the user can keep working in other apps; Esc is caught with
/// event monitors (global monitoring needs Accessibility; the Cancel button always works).
@MainActor
final class CountdownController {
    private let rect: CGRect
    private let total: Int
    private var remaining: Int
    private let completion: (_ fired: Bool) -> Void
    private var timer: Timer?
    private var outline: NSPanel?
    private var badge: NSPanel?
    private var dial: CountdownDial?
    private var monitors: [Any] = []
    private var done = false

    init(rect: CGRect, seconds: Int, completion: @escaping (_ fired: Bool) -> Void) {
        self.rect = rect
        self.total = max(1, seconds)
        self.remaining = max(1, seconds)
        self.completion = completion
    }

    func start() {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) && $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            ?? NSScreen.active
        if rect != screen.frame { outline = makeOutline() }
        badge = makeBadge(on: screen)
        outline?.orderFrontRegardless()
        badge?.orderFrontRegardless()

        let escape: (NSEvent) -> Bool = { $0.keyCode == UInt16(kVK_Escape) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard escape(e) else { return e }
            MainActor.assumeIsolated { self?.finish(fired: false) }
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard escape(e) else { return }
            Task { @MainActor in self?.finish(fired: false) }
        }) { monitors.append(m) }

        Sound.play(.countdownTick)
        dial?.show(remaining: remaining, progress: 1 / CGFloat(total))
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() { finish(fired: false) }

    private func tick() {
        guard !done else { return }
        remaining -= 1
        if remaining <= 0 { finish(fired: true); return }
        dial?.show(remaining: remaining, progress: CGFloat(total - remaining + 1) / CGFloat(total))
        Sound.play(.countdownTick)
    }

    private func finish(fired: Bool) {
        guard !done else { return }
        done = true
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        for p in [outline, badge] { p?.orderOut(nil); p?.close() }
        // May run inside the badge's Cancel button action: release the panels on the next turn.
        let retired = (outline, badge)
        outline = nil
        badge = nil
        DispatchQueue.main.async { withExtendedLifetime(retired) {} }
        completion(fired)
    }

    // MARK: Windows

    private func basePanel(_ frame: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = overlayWindowLevel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.setFrame(frame, display: false)
        return p
    }

    private func makeOutline() -> NSPanel {
        let p = basePanel(rect.insetBy(dx: -3, dy: -3))
        p.ignoresMouseEvents = true
        p.contentView = DashedOutlineView()
        return p
    }

    private func makeBadge(on screen: NSScreen) -> NSPanel {
        let size = CGSize(width: CountdownDial.diameter, height: CountdownDial.diameter)
        var frame = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        frame = SelectionGeometry.clamped(frame, to: screen.frame).integral
        let p = basePanel(frame)
        let view = CountdownDial(frame: CGRect(origin: .zero, size: size)) { [weak self] in self?.finish(fired: false) }
        dial = view
        p.contentView = view
        return p
    }
}

/// ~80 pt black disc (90%) with a bold white digit and a white progress arc along its inner edge;
/// hovering swaps the digit for a cancel cross.
@MainActor
private final class CountdownDial: NSView {
    static let diameter: CGFloat = 80

    private let onCancel: () -> Void
    private let digit = NSTextField(labelWithString: "")
    private let cross = NSImageView()
    private let arc = CAShapeLayer()
    private var tracking: NSTrackingArea?

    init(frame: CGRect, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true
        let disc = CAShapeLayer()
        disc.path = CGPath(ellipseIn: bounds, transform: nil)
        disc.fillColor = NSColor.black.withAlphaComponent(0.9).cgColor
        layer?.addSublayer(disc)

        let ringRect = bounds.insetBy(dx: 5, dy: 5)
        let ring = CGMutablePath()
        // Clockwise from 12 o'clock.
        ring.addArc(center: CGPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        arc.path = ring
        arc.fillColor = nil
        arc.strokeColor = NSColor.white.cgColor
        arc.lineWidth = 3
        arc.lineCap = .round
        arc.strokeEnd = 0
        layer?.addSublayer(arc)

        digit.font = .systemFont(ofSize: 44, weight: .bold)
        digit.textColor = .white
        digit.alignment = .center
        cross.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .bold))
        cross.contentTintColor = .white
        cross.isHidden = true
        for v in [digit, cross] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: centerXAnchor), v.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        toolTip = "Cancel (Esc)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Cancel self-timer")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(remaining: Int, progress: CGFloat) {
        digit.stringValue = "\(remaining)"
        // Fill toward this second's mark over the coming second.
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = arc.presentation()?.strokeEnd ?? arc.strokeEnd
        anim.toValue = progress
        anim.duration = 1
        arc.strokeEnd = progress
        arc.add(anim, forKey: "progress")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { digit.isHidden = true; cross.isHidden = false }
    override func mouseExited(with event: NSEvent) { digit.isHidden = false; cross.isHidden = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onCancel() }
    }
    override func accessibilityPerformPress() -> Bool { onCancel(); return true }
}

/// Dashed white/black outline marking the area that will be captured.
private final class DashedOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        path.stroke()
    }
}
