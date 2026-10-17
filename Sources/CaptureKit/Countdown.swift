import AppKit
import Carbon.HIToolbox
import ShotcraftCore

/// Self-Timer countdown (CleanShot: `SelfTimerOverlay` – `seconds`, `secondsLabel`, `cancelButton`,
/// `intervalTimer`). Shows large digits over the area, outlines it, ticks every second and then fires.
/// The panels never take keyboard focus so the user can keep working in other apps; Esc is caught with
/// event monitors (global monitoring needs Accessibility; the Cancel button always works).
@MainActor
final class CountdownController {
    private let rect: CGRect
    private var remaining: Int
    private let completion: (_ fired: Bool) -> Void
    private var timer: Timer?
    private var outline: NSPanel?
    private var badge: NSPanel?
    private var label: NSTextField?
    private var monitors: [Any] = []
    private var done = false

    init(rect: CGRect, seconds: Int, completion: @escaping (_ fired: Bool) -> Void) {
        self.rect = rect
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
        label?.stringValue = "\(remaining)"
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
        let size = CGSize(width: 150, height: 170)
        var frame = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        frame = SelectionGeometry.clamped(frame, to: screen.frame)
        let p = basePanel(frame)

        let box = HUDBox(spacing: 6, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        box.stack.orientation = .vertical
        box.stack.alignment = .centerX
        box.layer?.cornerRadius = 22
        let digits = NSTextField(labelWithString: "\(remaining)")
        digits.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        digits.textColor = .white
        digits.alignment = .center
        label = digits
        let caption = NSTextField(labelWithString: "Self-Timer")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        let cancel = FirstMouseButton(title: "Cancel", prominent: false) { [weak self] in self?.finish(fired: false) }
        box.stack.addArrangedSubview(digits)
        box.stack.addArrangedSubview(caption)
        box.stack.addArrangedSubview(cancel)
        box.frame = CGRect(origin: .zero, size: size)
        box.autoresizingMask = [.width, .height]
        let root = NSView(frame: box.frame)
        root.addSubview(box)
        p.contentView = root
        return p
    }
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
