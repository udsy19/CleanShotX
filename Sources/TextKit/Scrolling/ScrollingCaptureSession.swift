import AppKit
import ShotcraftCore

/// One scrolling capture, from the selected area to the stitched image (SGOverlay + ScrollingGrabber).
@MainActor final class ScrollingCaptureSession {
    private enum State { case ready, capturing, finishing, ended }

    static let maxLength = 30_000
    private static let slowDownText = "Please slow down..."
    private static let pausedText = "Paused — scroll down to continue"

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
    private var limitReached = false
    private var frameTimer: Timer?
    private var autoScrollTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var monitors: [Any] = []

    // Windows
    private let frameWindow = OverlayPanel(clickThrough: true)
    private let frameView = AreaFrameView()
    private let controls = ScrollingControls()
    private let preview = PreviewPanel()
    private let hint = HintPanel()

    init(area: CGRect, screen: NSScreen, options: CaptureOptions, onEnd: @escaping () -> Void) {
        self.area = area.integral.intersection(screen.frame)
        self.screen = screen
        self.options = options
        self.onEnd = onEnd
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
        controls.onAutoScroll = { [weak self] axis, on in self?.setAutoScroll(on, axis: axis) }
        NSApp.activate(ignoringOtherApps: true)
        controls.place(in: area, on: screen)
        installKeyMonitors()
    }

    /// Esc / Cancel: works in every state, including while the result is being rendered.
    func cancel() { end() }

    /// Tears everything down exactly once; safe to call from any state.
    private func end() {
        guard state != .ended else { return }
        state = .ended
        stopFrameTimer()
        autoScrollTask?.cancel(); autoScrollTask = nil
        finishTask?.cancel(); finishTask = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        controls.close()
        preview.hide()
        hint.hide()
        frameWindow.orderOut(nil)
        engine = nil   // releases the stitched strips
        onEnd()
    }

    private func installKeyMonitors() {
        let handle: (NSEvent) -> Bool = { [weak self] event in
            guard let self, self.state != .ended else { return false }
            switch event.keyCode {
            case 53: self.cancel(); return true                       // Esc
            case 36, 76:                                               // Return / Enter
                if self.state == .ready { self.startCapturing() } else { self.finish() }
                return true
            default: return false
            }
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handle($0) ? nil : $0 }) { monitors.append(local) }
        // Delivered only with Accessibility permission; lets Esc cancel while another app is frontmost.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in
            if e.keyCode == 53 { MainActor.assumeIsolated { _ = handle(e) } }
        }) { monitors.append(global) }
    }

    // MARK: Capturing

    private func startCapturing(autoScroll axis: ScrollAxis? = nil) {
        guard state == .ready else { return }
        state = .capturing
        engine = ScrollEngine(maxLength: Self.maxLength)
        controls.setCapturing()
        updateGuidance()
        Task { @MainActor in
            await self.captureFrame()
            guard self.state == .capturing else { return }
            if let axis { self.setAutoScroll(true, axis: axis) } else { self.startFrameTimer() }
        }
    }

    private func startFrameTimer() {
        stopFrameTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .capturing, self.autoScrollTask == nil else { return }
                self.updateGuidance()
                guard !self.captureInFlight else { return }
                Task { @MainActor in await self.captureFrame() }
            }
        }
        // `.common` keeps grabbing while the help popover or a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
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
        guard state != .ended else { return nil }
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
        }
        preview.update(u, area: area, screen: screen)
        switch u.event {
        case .appended:
            hasMatched = true
            hint.hide(Self.slowDownText)
            hint.hide(Self.pausedText)
        case .noOverlap:
            hint.show(Self.slowDownText, symbol: "tortoise.fill", style: .warning, duration: 1.5, shake: true)
        case .reversed:
            if hint.currentText != Self.slowDownText {
                hint.show(Self.pausedText, symbol: "pause.circle.fill", style: .warning, duration: 1.5)
            }
        case .limitReached:
            limitReached = true
            stopFrameTimer()
            stopAutoScroll()
            hint.show("Screenshot is very large", symbol: "exclamationmark.triangle.fill", style: .warning)
        case .started, .identical:
            break
        }
    }

    /// Persistent guidance until the first movement is stitched.
    private func updateGuidance() {
        guard state == .capturing, !hasMatched, autoScrollTask == nil else { return }
        if let t = hint.currentText, t == Self.slowDownText || t == Self.pausedText { return }
        if !NSMouseInRect(NSEvent.mouseLocation, area, false) {
            hint.show("Move cursor here to start scrolling", symbol: "cursorarrow.motionlines")
            return
        }
        switch detectedAxis {
        case .vertical: hint.show("Slowly scroll down the content", symbol: "arrow.down")
        case .horizontal: hint.show("Slowly scroll right", symbol: "arrow.right")
        case nil: hint.show("Scroll Vertically or Horizontally", symbol: "arrow.up.and.down.and.arrow.left.and.right")
        }
    }

    // MARK: Auto-scroll

    private func setAutoScroll(_ on: Bool, axis requested: ScrollAxis) {
        guard on else {
            stopAutoScroll()
            if state == .capturing, !limitReached { startFrameTimer() }
            return
        }
        // Synthetic scroll events are silently dropped without Accessibility permission.
        guard Permissions.hasAccessibility else {
            controls.setAutoScroll(false)
            Permissions.requestAccessibility()
            hint.show("Auto-Scroll needs Accessibility permission", symbol: "lock.shield", style: .warning, duration: 3)
            return
        }
        if state == .ready { startCapturing(autoScroll: requested); return }
        guard state == .capturing, autoScrollTask == nil, !limitReached, let engine else { controls.setAutoScroll(false); return }
        let axis = detectedAxis ?? requested
        if detectedAxis == nil {
            detectedAxis = axis
            controls.setDetectedAxis(axis)
            engine.queue.async { engine.lock(axis) }
        }
        guard let point = scrollPoint() else {
            hint.show("Select a larger area to use Auto-Scroll", symbol: "exclamationmark.triangle.fill", style: .warning, duration: 2)
            controls.setAutoScroll(false)
            return
        }
        stopFrameTimer()
        controls.setAutoScroll(true)
        hint.hide()
        // Scroll events go to the window under the cursor: park it in the area, clear of our controls.
        CGWarpMouseCursorPosition(ScreenGeometry.cgPoint(fromCocoa: point))
        CGAssociateMouseAndMouseCursorPosition(1)
        let initialStep = min(400, (axis == .vertical ? area.height : area.width) * 0.35)
        autoScrollTask = Task { @MainActor [weak self] in
            await self?.runAutoScroll(axis: axis, step: initialStep, at: point)
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        controls.setAutoScroll(false)
    }

    /// A point inside the area that none of our control panels cover.
    private func scrollPoint() -> CGPoint? {
        let covered = controls.coveredFrames
        let candidates = [CGPoint(x: area.midX, y: area.midY),
                          CGPoint(x: area.midX, y: area.maxY - area.height * 0.25),
                          CGPoint(x: area.minX + area.width * 0.25, y: area.midY)]
        return candidates.first { p in !covered.contains { $0.insetBy(dx: -4, dy: -4).contains(p) } }
    }

    private func runAutoScroll(axis: ScrollAxis, step initialStep: CGFloat, at point: CGPoint) async {
        var step = initialStep
        var unchanged = 0
        var first = true
        func running() -> Bool { !Task.isCancelled && state == .capturing }
        while running() {
            // The user took the cursor away: scroll events would land elsewhere.
            if !first, !NSMouseInRect(NSEvent.mouseLocation, area, false) {
                stopAutoScroll()
                startFrameTimer()
                hint.show("Auto-Scroll stopped — the cursor left the area", symbol: "cursorarrow.motionlines", duration: 2)
                return
            }
            first = false
            postScroll(by: step, axis: axis, at: point)
            try? await Task.sleep(nanoseconds: 350_000_000)   // let smooth scrolling settle
            var update: ScrollUpdate?
            while running(), update == nil {
                update = await captureFrame()
                if update == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
            guard running(), let update else { return }
            switch update.event {
            case .appended:
                unchanged = 0
            case .identical, .started:
                unchanged += 1
                if unchanged >= 3 { autoScrollTask = nil; finish(); return }   // reached the end of the content
            case .noOverlap:
                postScroll(by: -step, axis: axis, at: point)
                step = max(24, step / 2)
                try? await Task.sleep(nanoseconds: 300_000_000)
            case .reversed:
                break
            case .limitReached:
                return
            }
        }
    }

    /// Posts pixel-unit scroll-wheel events at `point`. Positive = forward (down / right).
    private func postScroll(by points: CGFloat, axis: ScrollAxis, at point: CGPoint) {
        let location = ScreenGeometry.cgPoint(fromCocoa: point)
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
        stopFrameTimer()
        autoScrollTask?.cancel(); autoScrollTask = nil
        hint.hide()
        finishTask = Task { @MainActor in
            while self.captureInFlight, self.state == .finishing { try? await Task.sleep(nanoseconds: 20_000_000) }
            guard self.state == .finishing, let engine = self.engine else { return }
            let hasFrames = await withCheckedContinuation { c in engine.queue.async { c.resume(returning: engine.hasFrames) } }
            if !hasFrames { await self.captureFrame() }
            let image = await withCheckedContinuation { c in engine.queue.async { c.resume(returning: engine.render()) } }
            guard self.state == .finishing else { return }   // cancelled while rendering
            let scale = self.screen.backingScaleFactor
            let actions = self.options.actions
            self.end()
            guard let image else { Alerts.error("Screen content error"); return }
            MediaPipeline.didCaptureImage(image, scale: scale, mode: .scrolling, actions: actions)
        }
    }
}
