import AppKit
import ShotcraftCore

// MARK: - Countdown (CountDownOverlay)

/// Black 80-pt disc centred in the area with a big white digit and a progress arc. Click starts now,
/// hovering reveals a cancel button, Esc cancels, Return starts.
@MainActor
final class CountdownOverlay {
    private let panel: RecorderPanel
    private let label = NSTextField(labelWithString: "")
    private let ring = CAShapeLayer()
    private let cancelButton = NSButton()
    private var remaining: Int
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?
    private var keyMonitor: Any?

    private static let disc: CGFloat = 80
    private static let side: CGFloat = 112   // room for the hover cancel button

    init(area: CGRect, seconds: Int) {
        remaining = max(1, seconds)
        let side = Self.side, disc = Self.disc
        let frame = NSRect(x: (area.midX - side / 2).rounded(), y: (area.midY - side / 2).rounded(), width: side, height: side)
        panel = RecorderPanel(frame: frame, level: RecorderLevel.controls, clickThrough: false)
        panel.allowsKey = true
        let content = CountdownView(frame: NSRect(origin: .zero, size: frame.size))
        let circle = NSView(frame: NSRect(x: (side - disc) / 2, y: (side - disc) / 2, width: disc, height: disc))
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        circle.layer?.cornerRadius = disc / 2
        circle.toolTip = "Click to start recording now"
        label.font = .systemFont(ofSize: 44, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (disc - 54) / 2, width: disc, height: 54)
        circle.addSubview(label)
        // Progress arc clockwise from 12 o'clock just inside the rim.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: disc / 2, y: disc / 2), radius: disc / 2 - 5, startAngle: 90, endAngle: -270, clockwise: true)
        ring.path = arc.cgPath
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 3
        ring.lineCap = .round
        ring.strokeEnd = 0
        circle.layer?.addSublayer(ring)
        content.addSubview(circle)

        cancelButton.isBordered = false
        cancelButton.bezelStyle = .regularSquare
        cancelButton.image = symbol("xmark.circle.fill", size: 20, weight: .semibold)
        cancelButton.contentTintColor = .white
        cancelButton.toolTip = "Cancel Recording"
        cancelButton.setAccessibilityLabel("Cancel Recording")
        cancelButton.frame = NSRect(x: circle.frame.maxX - 16, y: circle.frame.maxY - 16, width: 26, height: 26)
        cancelButton.wantsLayer = true
        cancelButton.layer?.shadowOpacity = 0.5
        cancelButton.layer?.shadowRadius = 3
        cancelButton.isHidden = true
        content.addSubview(cancelButton)
        panel.contentView = content

        content.onClick = { [weak self] in self?.finish(true) }
        content.onHover = { [weak self] inside in self?.cancelButton.isHidden = !inside }
        cancelButton.target = content
        cancelButton.action = #selector(CountdownView.cancelClicked)
        content.onCancel = { [weak self] in self?.finish(false) }
    }

    func run(completion: @escaping (_ start: Bool) -> Void) {
        self.completion = completion
        update()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(false); return nil }          // Esc
            if e.keyCode == 36 || e.keyCode == 76 { self?.finish(true); return nil } // Return / Enter
            return e
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 { finish(true) } else { update() }
    }

    private func update() {
        label.stringValue = "\(remaining)"
        Sound.play(.countdownTick)
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0; anim.toValue = 1; anim.duration = 1
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        ring.add(anim, forKey: "tick")
    }

    private func finish(_ start: Bool) {
        guard let completion else { return }
        self.completion = nil
        timer?.invalidate(); timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
        completion(start)
    }

    func cancel() { finish(false) }
}

private final class CountdownView: NSView {
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the disc and the cancel button are clickable; the transparent margin isn't.
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    @objc func cancelClicked() { onCancel?() }
}

// MARK: - Controls (RecorderControlsView)

/// Dark pill shown while recording: red stop + timer (with a mic level meter) | pause/resume | restart |
/// delete | drag grip. Excluded from the capture.
@MainActor
final class RecordingControlsPanel: NSObject {
    let panel: RecorderPanel
    private let pauseButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let meter = CALayer()
    private let meterWidth: CGFloat = 38
    private let actions: Actions

    struct Actions {
        var stop: () -> Void
        var togglePause: () -> Void
        var restart: () -> Void
        var delete: () -> Void
    }

    private static let height: CGFloat = 40
    private static let stopWidth: CGFloat = 80
    private static let iconWidth: CGFloat = 40
    private static let gripWidth: CGFloat = 22

    init(area: CGRect, screen: NSScreen, showsMeter: Bool, actions: Actions) {
        self.actions = actions
        panel = RecorderPanel(frame: .zero, level: RecorderLevel.controls, clickThrough: false)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        super.init()

        let h = Self.height
        let width = Self.stopWidth + Self.iconWidth * 3 + Self.gripWidth + 4
        let pill = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0x16 / 255.0, alpha: 0.95).cgColor
        pill.layer?.cornerRadius = h / 2
        pill.layer?.cornerCurve = .continuous
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        pill.appearance = NSAppearance(named: .darkAqua)

        var x: CGFloat = 0
        func separator() {
            pill.addSubview(RecorderStyle.line(NSRect(x: x, y: 10, width: 1, height: h - 20)).tinted(alpha: 0.1))
            x += 1
        }

        // 1. Stop + timer.
        let stop = NSButton()
        configure(stop, "stop.circle", "Stop Recording", #selector(stopClicked), tint: .systemRed)
        stop.frame = NSRect(x: 8, y: 0, width: 28, height: h)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timeLabel.textColor = .systemRed
        timeLabel.frame = NSRect(x: 37, y: showsMeter ? 13 : 10, width: Self.stopWidth - 39, height: 19)
        pill.addSubview(stop)
        pill.addSubview(timeLabel)
        if showsMeter {
            let track = CALayer()
            track.frame = CGRect(x: 38, y: 8, width: meterWidth, height: 2)
            track.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            track.cornerRadius = 1
            meter.frame = CGRect(x: 38, y: 8, width: 0, height: 2)
            meter.backgroundColor = NSColor.systemGreen.cgColor
            meter.cornerRadius = 1
            pill.layer?.addSublayer(track)
            pill.layer?.addSublayer(meter)
        }
        x = Self.stopWidth
        separator()

        // 2–4. Pause / restart / delete.
        let restart = NSButton(), trash = NSButton()
        configure(pauseButton, "pause.circle", "Pause Recording", #selector(pauseClicked))
        configure(restart, "arrow.counterclockwise", "Restart Recording", #selector(restartClicked))
        configure(trash, "trash", "Delete Recording", #selector(trashClicked))
        for (i, b) in [pauseButton, restart, trash].enumerated() {
            b.frame = NSRect(x: x, y: 0, width: Self.iconWidth, height: h)
            pill.addSubview(b)
            x += Self.iconWidth
            if i < 2 { separator() }
        }
        separator()

        // 5. Drag grip (the whole background drags too).
        let grip = NSImageView(image: symbol("line.3.horizontal", size: 12, weight: .semibold))
        grip.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        grip.frame = NSRect(x: x, y: 0, width: width - x - 4, height: h)
        grip.toolTip = "Drag to move"
        pill.addSubview(grip)

        panel.contentView = pill
        panel.setFrame(Self.placement(for: pill.frame.size, area: area, screen: screen), display: false)
    }

    private func configure(_ b: NSButton, _ icon: String, _ tip: String, _ sel: Selector, tint: NSColor = .white) {
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.image = symbol(icon, size: 17, weight: .regular)
        b.imagePosition = .imageOnly
        b.contentTintColor = tint
        b.toolTip = tip
        b.target = self
        b.action = sel
        b.setAccessibilityLabel(tip)
    }

    /// Below the area, else above it, else inside its bottom edge.
    static func placement(for size: CGSize, area: CGRect, screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let gap: CGFloat = 12
        var y: CGFloat
        if area.minY - gap - size.height >= vf.minY { y = area.minY - gap - size.height }
        else if area.maxY + gap + size.height <= vf.maxY { y = area.maxY + gap }
        else { y = max(vf.minY, area.minY) + gap }
        var x = area.midX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }

    func update(elapsed: String, paused: Bool) {
        timeLabel.stringValue = elapsed
        pauseButton.image = symbol(paused ? "play.circle" : "pause.circle", size: 17, weight: .regular)
        pauseButton.toolTip = paused ? "Resume Recording" : "Pause Recording"
        pauseButton.setAccessibilityLabel(pauseButton.toolTip)
        timeLabel.textColor = paused ? NSColor.white.withAlphaComponent(0.6) : .systemRed
    }

    /// Microphone level 0…1.
    func setLevel(_ level: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        meter.frame.size.width = meterWidth * max(0, min(1, level))
        meter.backgroundColor = (level > 0.85 ? NSColor.systemOrange : NSColor.systemGreen).cgColor
        CATransaction.commit()
    }

    @objc private func stopClicked() { actions.stop() }
    @objc private func pauseClicked() { actions.togglePause() }
    @objc private func restartClicked() { actions.restart() }
    @objc private func trashClicked() { actions.delete() }
}

private extension NSView {
    func tinted(alpha: CGFloat) -> NSView {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        return self
    }
}

// MARK: - GIF processing popup (GIFProcessingPopup)

/// Small HUD in the bottom-right corner with progress and Cancel while a GIF is being encoded.
@MainActor
final class GIFProcessingPopup: NSObject {
    private let panel: RecorderPanel
    private let bar = NSProgressIndicator()
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = RecorderPanel(frame: .zero, level: RecorderLevel.controls, clickThrough: false)
        panel.hasShadow = true
        super.init()
        let fx = RecorderStyle.glass(cornerRadius: 14)
        let title = NSTextField(labelWithString: "Creating GIF…")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.style = .bar
        bar.controlSize = .small
        bar.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.controlSize = .small
        let column = NSStackView(views: [title, bar])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
        let icon = NSImageView(image: symbol("photo.stack", size: 22))
        icon.contentTintColor = .white
        let row = NSStackView(views: [icon, column, cancel])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: fx.leadingAnchor), row.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            row.topAnchor.constraint(equalTo: fx.topAnchor), row.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        let size = row.fittingSize
        panel.contentView = fx
        let vf = NSScreen.active.visibleFrame
        panel.setFrame(NSRect(x: vf.maxX - size.width - 20, y: vf.minY + 20, width: size.width, height: size.height), display: false)
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil); StatusBar.setProgress(nil) }

    func setProgress(_ p: Double) {
        bar.doubleValue = p
        StatusBar.setProgress(p)
    }

    @objc private func cancelClicked() { onCancel() }
}
