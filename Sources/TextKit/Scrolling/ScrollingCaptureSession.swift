import AppKit
import ShotcraftCore

/// One scrolling capture, from the selected area to the stitched image (SGOverlay + ScrollingGrabber).
@MainActor final class ScrollingCaptureSession {
    private enum State { case ready, capturing, finishing, ended }

    static let maxLength = 30_000

    private let area: CGRect
    private let screen: NSScreen
    private let options: CaptureOptions
    private let onEnd: () -> Void

    private var state = State.ready
    private var engine: ScrollEngine?
    private var detectedAxis: ScrollAxis?
    private var captureInFlight = false
    private var captureErrors = 0
    private var hasMatched = false
    private var frameTimer: Timer?
    private var monitors: [Any] = []

    // Auto-scroll
    private var autoScrolling = false
    private var autoStep: CGFloat = 0
    private var unchangedCount = 0

    // Windows
    private let frameWindow: NSWindow
    private let frameView = AreaFrameView()
    private let controls = ScrollingControls()
    private let preview = PreviewPanel()
    private let hint = HintPanel()

    init(area: CGRect, screen: NSScreen, options: CaptureOptions, onEnd: @escaping () -> Void) {
        self.area = area.integral.intersection(screen.frame)
        self.screen = screen
        self.options = options
        self.onEnd = onEnd
        frameWindow = ScrollingPanel(contentRect: screen.frame, clickThrough: true)
        frameWindow.level = .floating
        frameView.area = self.area.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        frameWindow.contentView = frameView
        hint.anchor = CGPoint(x: self.area.midX, y: self.area.midY)
    }

    // MARK: Lifecycle

    func begin() {
        frameWindow.setFrame(screen.frame, display: true)
        frameWindow.orderFrontRegardless()
        controls.onStart = { [weak self] in self?.startCapturing() }
        controls.onDone = { [weak self] in self?.finish() }
        controls.onCancel = { [weak self] in self?.cancel() }
        controls.onAutoScroll = { [weak self] on in self?.setAutoScroll(on) }
        controls.onOrientation = { [weak self] _ in self?.updateGuidance() }
        NSApp.activate(ignoringOtherApps: true)
        controls.place(below: area, on: screen)
        installKeyMonitors()
    }

    func cancel() {
        guard state != .ended else { return }
        end()
    }

    private func end() {
        state = .ended
        frameTimer?.invalidate(); frameTimer = nil
        autoScrolling = false
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        controls.close()
        preview.panel.orderOut(nil)
        hint.hide()
        frameWindow.orderOut(nil)
        onEnd()
    }

    private func installKeyMonitors() {
        let handle: (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            switch event.keyCode {
            case 53: self.cancel(); return true                       // Esc
            case 36, 76:                                               // Return / Enter
                if self.state == .ready { self.startCapturing() } else { self.finish() }
                return true
            default: return false
            }
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handle($0) ? nil : $0 }) { monitors.append(local) }
        // Works only with Accessibility permission; lets Esc cancel while another app is frontmost.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in
            if e.keyCode == 53 { MainActor.assumeIsolated { _ = handle(e) } }
        }) { monitors.append(global) }
    }

    // MARK: Capturing

    private func startCapturing(auto: Bool = false) {
        guard state == .ready else { return }
        state = .capturing
        let choice = controls.orientation
        engine = ScrollEngine(axis: choice.axis, maxLength: Self.maxLength)
        if let axis = choice.axis { detectedAxis = axis; controls.setDetectedAxis(axis) }
        controls.setCapturing()
        controls.setCounter(frames: 0)
        frameView.isActive = true
        preview.place(around: area, on: screen, axis: detectedAxis ?? .vertical, avoiding: controls.panel.frame)
        Task { @MainActor in
            await self.captureFrame()
            guard self.state == .capturing else { return }
            if auto { self.setAutoScroll(true) } else { self.startFrameTimer() }
        }
        updateGuidance()
    }

    private func startFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .capturing, !self.autoScrolling else { return }
                self.updateGuidance()
                guard !self.captureInFlight else { return }
                Task { @MainActor in await self.captureFrame() }
            }
        }
    }

    /// Grabs the area (our windows are excluded) and runs it through the stitcher off the main thread.
    @discardableResult
    private func captureFrame() async -> ScrollUpdate? {
        guard let engine, !captureInFlight, state == .capturing || state == .finishing else { return nil }
        captureInFlight = true
        defer { captureInFlight = false }
        let image: CGImage
        do {
            image = try await ScreenCapturer.capture(rect: area, on: screen, showsCursor: false)
            captureErrors = 0
        } catch {
            captureErrors += 1
            if captureErrors >= 5, state == .capturing {
                end()
                Alerts.error("Screen content error", error)
            }
            return nil
        }
        let update = await withCheckedContinuation { (cont: CheckedContinuation<ScrollUpdate, Never>) in
            engine.queue.async { cont.resume(returning: engine.process(image)) }
        }
        if state == .capturing { apply(update) }
        return update
    }

    private func apply(_ u: ScrollUpdate) {
        if let axis = u.axis, axis != detectedAxis {
            detectedAxis = axis
            controls.setDetectedAxis(axis)
            preview.place(around: area, on: screen, axis: axis, avoiding: controls.panel.frame)
        }
        controls.setCounter(frames: u.frames)
        preview.update(u)
        switch u.event {
        case .appended:
            hasMatched = true
            hint.hide("Please slow down...")
            hint.hide(Self.pausedText)
            updateGuidance()
        case .noOverlap:
            hint.show("Please slow down...", symbol: "tortoise.fill", style: .warning, duration: 1.5, shake: true)
        case .reversed:
            if hint.currentText != "Please slow down..." {
                hint.show(Self.pausedText, symbol: "pause.circle.fill", style: .warning, duration: 1.5)
            }
        case .limitReached:
            frameTimer?.invalidate(); frameTimer = nil
            autoScrolling = false
            controls.setAutoScroll(false)
            hint.show("Screenshot is very large", symbol: "exclamationmark.triangle.fill", style: .warning)
        case .started, .identical:
            break
        }
    }

    private static var pausedText: String { "Paused — scroll forward to continue" }

    /// Persistent guidance until the first movement is stitched.
    private func updateGuidance() {
        guard state == .capturing, !hasMatched, !autoScrolling else { return }
        if let t = hint.currentText, t == "Please slow down..." || t == Self.pausedText { return }
        if !NSMouseInRect(NSEvent.mouseLocation, area, false) {
            hint.show("Move cursor here to start scrolling", symbol: "cursorarrow.motionlines")
            return
        }
        switch detectedAxis ?? controls.orientation.axis {
        case .vertical: hint.show("Slowly scroll down the content", symbol: "arrow.down")
        case .horizontal: hint.show("Slowly scroll right", symbol: "arrow.right")
        case nil: hint.show("Scroll Vertically or Horizontally", symbol: "arrow.up.and.down.and.arrow.left.and.right")
        }
    }

    // MARK: Auto-scroll

    private func setAutoScroll(_ on: Bool) {
        guard on else { autoScrolling = false; controls.setAutoScroll(false); if state == .capturing { startFrameTimer() }; return }
        guard Permissions.hasAccessibility else {
            controls.setAutoScroll(false)
            Permissions.requestAccessibility()
            hint.show("Auto-Scroll needs Accessibility permission", symbol: "lock.shield", style: .warning, duration: 3)
            return
        }
        if state == .ready { startCapturing(auto: true); return }
        guard state == .capturing, !autoScrolling else { return }
        let axis = detectedAxis ?? controls.orientation.axis ?? .vertical
        if detectedAxis == nil {
            detectedAxis = axis
            controls.setDetectedAxis(axis)
            preview.place(around: area, on: screen, axis: axis, avoiding: controls.panel.frame)
            if let engine { engine.queue.async { engine.lock(axis) } }
        }
        frameTimer?.invalidate(); frameTimer = nil
        autoScrolling = true
        controls.setAutoScroll(true)
        hint.hide()
        autoStep = min(400, (axis == .vertical ? area.height : area.width) * 0.35)
        unchangedCount = 0
        // Synthetic scroll events go to the window under the cursor: park it in the area.
        CGWarpMouseCursorPosition(ScreenGeometry.cgPoint(fromCocoa: CGPoint(x: area.midX, y: area.midY)))
        CGAssociateMouseAndMouseCursorPosition(1)
        autoScrollTick()
    }

    private func autoScrollTick() {
        guard autoScrolling, state == .capturing, let axis = detectedAxis else { return }
        postScroll(by: autoStep, axis: axis)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)   // let smooth scrolling settle
            guard self.autoScrolling, self.state == .capturing else { return }
            guard let update = await self.captureFrame() else { self.autoScrollTick(); return }
            switch update.event {
            case .appended:
                self.unchangedCount = 0
            case .identical, .started:
                self.unchangedCount += 1
                if self.unchangedCount >= 3 { self.finish(); return }   // reached the end of the content
            case .noOverlap:
                self.postScroll(by: -self.autoStep, axis: axis)
                self.autoStep = max(24, self.autoStep / 2)
                try? await Task.sleep(nanoseconds: 300_000_000)
            case .reversed:
                break
            case .limitReached:
                return
            }
            self.autoScrollTick()
        }
    }

    /// Posts pixel-unit scroll-wheel events at the area centre. Positive = forward (down / right).
    private func postScroll(by points: CGFloat, axis: ScrollAxis) {
        let location = ScreenGeometry.cgPoint(fromCocoa: CGPoint(x: area.midX, y: area.midY))
        var remaining = Int(points.rounded())
        while remaining != 0 {
            let chunk = remaining > 0 ? min(remaining, 60) : max(remaining, -60)
            remaining -= chunk
            let delta = Int32(-chunk)
            let event = axis == .vertical
                ? CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
                : CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0)
            event?.location = location
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Finish

    func finish() {
        guard state == .capturing else { return }
        state = .finishing
        frameTimer?.invalidate(); frameTimer = nil
        autoScrolling = false
        hint.hide()
        Task { @MainActor in
            while self.captureInFlight { try? await Task.sleep(nanoseconds: 20_000_000) }
            guard let engine = self.engine else { self.end(); return }
            let hasFrames = await withCheckedContinuation { c in engine.queue.async { c.resume(returning: engine.hasFrames) } }
            if !hasFrames { await self.captureFrame() }
            let image = await withCheckedContinuation { c in engine.queue.async { c.resume(returning: engine.render()) } }
            let scale = self.screen.backingScaleFactor
            let actions = self.options.actions
            self.end()
            guard let image else { Alerts.error("Screen content error"); return }
            MediaPipeline.didCaptureImage(image, scale: scale, mode: .scrolling, actions: actions)
        }
    }
}
