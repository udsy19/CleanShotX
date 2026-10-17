import AppKit
import ShotcraftCore

// MARK: - Countdown (CountDownOverlay)

/// Big translucent countdown centered in the area. Click skips, Esc cancels.
@MainActor
final class CountdownOverlay {
    private let panel: RecorderPanel
    private let label = NSTextField(labelWithString: "")
    private let ring = CAShapeLayer()
    private var remaining: Int
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?
    private var keyMonitor: Any?

    init(area: CGRect, seconds: Int) {
        remaining = max(1, seconds)
        let side: CGFloat = 150
        let frame = NSRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
        panel = RecorderPanel(frame: frame, level: RecorderLevel.controls, clickThrough: false)
        panel.allowsKey = true
        let fx = ClickView(frame: NSRect(origin: .zero, size: frame.size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = side / 2
        fx.layer?.masksToBounds = true
        fx.onClick = { [weak self] in self?.finish(true) }
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (side - 88) / 2, width: side, height: 88)
        fx.addSubview(label)
        ring.path = CGPath(ellipseIn: fx.bounds.insetBy(dx: 6, dy: 6), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        ring.lineWidth = 4
        ring.lineCap = .round
        fx.layer?.addSublayer(ring)
        fx.toolTip = "Click to start recording now"
        panel.contentView = fx
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
        anim.fromValue = 1; anim.toValue = 0; anim.duration = 1
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

private final class ClickView: NSVisualEffectView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controls (RecorderControlsView)

/// Floating Stop / Pause / Restart / Delete bar shown while recording. Excluded from the capture.
@MainActor
final class RecordingControlsPanel: NSObject {
    let panel: RecorderPanel
    private let stopButton = NSButton()
    private let pauseButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let actions: Actions

    struct Actions {
        var stop: () -> Void
        var togglePause: () -> Void
        var restart: () -> Void
        var delete: () -> Void
    }

    init(area: CGRect, screen: NSScreen, actions: Actions) {
        self.actions = actions
        panel = RecorderPanel(frame: .zero, level: RecorderLevel.controls, clickThrough: false)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        super.init()

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true

        stopButton.bezelStyle = .regularSquare
        stopButton.isBordered = false
        stopButton.image = symbol("stop.circle.fill", size: 18)
        stopButton.contentTintColor = .systemRed
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = "Stop Recording"
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .labelColor
        let stopStack = NSStackView(views: [stopButton, timeLabel])
        stopStack.spacing = 4

        configure(pauseButton, "pause.fill", "Pause Recording", #selector(pauseClicked))
        let restart = NSButton(), trash = NSButton()
        configure(restart, "arrow.counterclockwise", "Restart Recording", #selector(restartClicked))
        configure(trash, "trash", "Delete Recording", #selector(trashClicked))

        let sep = NSBox(); sep.boxType = .separator
        let stack = NSStackView(views: [stopStack, sep, pauseButton, restart, trash])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 18),
        ])
        timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let size = stack.fittingSize
        panel.contentView = fx
        panel.setFrame(Self.placement(for: size, area: area, screen: screen), display: false)
    }

    private func configure(_ b: NSButton, _ icon: String, _ tip: String, _ sel: Selector) {
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.image = symbol(icon, size: 15)
        b.contentTintColor = .labelColor
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
        pauseButton.image = symbol(paused ? "play.fill" : "pause.fill", size: 15)
        pauseButton.toolTip = paused ? "Resume Recording" : "Pause Recording"
        timeLabel.textColor = paused ? .secondaryLabelColor : .labelColor
    }

    @objc private func stopClicked() { actions.stop() }
    @objc private func pauseClicked() { actions.togglePause() }
    @objc private func restartClicked() { actions.restart() }
    @objc private func trashClicked() { actions.delete() }
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
        let fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12; fx.layer?.masksToBounds = true
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
        let row = NSStackView(views: [NSImageView(image: symbol("photo.stack", size: 22)), column, cancel])
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
