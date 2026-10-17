import AppKit
import SuperScreenshotCore

/// Logs cursor positions (~60 Hz), clicks, scrolls and keystrokes during a Studio recording
/// (FLMouseTracker + FLKeyboardTracker). Positions are normalized to the recorded area (top-left origin);
/// times come from the shared `RecordingClock`.
final class InputTracker: @unchecked Sendable {
    private let clock: RecordingClock
    /// Recorded area in CG global coordinates (top-left origin).
    private let cgArea: CGRect
    private let lock = NSLock()
    private var events = StudioEvents()
    private var timer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "superscreenshot.studio.cursor", qos: .userInteractive)
    private var monitors: [Any] = []
    private var kindTimer: Timer?
    private var currentKind: CursorKind = .arrow
    // Poll state (pollQueue only).
    private var lastRecorded: CursorSample?
    private var lastPolledTime: Double?

    /// - Parameter area: recorded rect in global Cocoa coordinates.
    @MainActor init(area: CGRect, clock: RecordingClock) {
        self.clock = clock
        cgArea = ScreenGeometry.cgRect(fromCocoa: area)
    }

    private func normalize(cg p: CGPoint) -> NPoint {
        NPoint(x: Double((p.x - cgArea.minX) / max(cgArea.width, 1)), y: Double((p.y - cgArea.minY) / max(cgArea.height, 1)))
    }

    @MainActor func start(recordKeys: Bool) {
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t

        // Cursor shape (arrow / I-beam / hand), sampled on the main thread.
        let k = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKind() }
        }
        RunLoop.main.add(k, forMode: .common)
        kindTimer = k

        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] e in self?.handleMouse(e) }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in self?.handleScroll(e) }) { monitors.append(m) }
        let canKeys = recordKeys && Permissions.hasAccessibility
        lock.lock(); events.keystrokesCaptured = canKeys; lock.unlock()
        if canKeys, let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.handleKey(e) }) {
            monitors.append(m)
        }
    }

    /// Stops tracking and returns everything logged.
    @MainActor func finish() -> StudioEvents {
        timer?.cancel(); timer = nil
        kindTimer?.invalidate(); kindTimer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        pollQueue.sync {}
        lock.lock(); defer { lock.unlock() }
        events.cursor.sort { $0.t < $1.t }
        return events
    }

    @MainActor private func updateKind() {
        let sys = NSCursor.currentSystem
        func same(_ a: NSCursor?, _ b: NSCursor) -> Bool {
            guard let a else { return false }
            return a.hotSpot == b.hotSpot && a.image.size == b.image.size
        }
        let kind: CursorKind = same(sys, .iBeam) ? .iBeam : same(sys, .pointingHand) ? .pointingHand : .arrow
        lock.lock(); currentKind = kind; lock.unlock()
    }

    private func poll() {
        let now = RecordingClock.hostNow()
        guard let t = clock.mediaTime(forHost: now), let loc = CGEvent(source: nil)?.location else { return }
        lock.lock(); let kind = currentKind; lock.unlock()
        let sample = CursorSample(t: t, p: normalize(cg: loc), kind: kind)
        defer { lastPolledTime = t }
        if let last = lastRecorded, last.p == sample.p, last.kind == sample.kind {
            // Unchanged: keep a sparse heartbeat so long idle stretches are still represented.
            guard t - last.t >= 0.5 else { return }
        } else if let last = lastRecorded, let polled = lastPolledTime, polled > last.t + 0.001 {
            // Movement after an idle stretch: anchor the old position just before it, so interpolation
            // doesn't drift across the whole idle period.
            append(CursorSample(t: polled, p: last.p, kind: last.kind))
        }
        append(sample)
        lastRecorded = sample
    }

    private func append(_ s: CursorSample) { lock.lock(); events.cursor.append(s); lock.unlock() }

    /// Media time of an event. `NSEvent.timestamp` and the host clock both count mach time since boot, so the
    /// event's own time is used (exact even when the monitor runs late); fall back to "now" if they disagree.
    private func mediaTime(of e: NSEvent) -> Double? {
        let now = RecordingClock.hostNow()
        return clock.mediaTime(forHost: abs(now - e.timestamp) < 1 ? e.timestamp : now)
    }

    /// Where the event happened (falls back to the current pointer location).
    private func point(of e: NSEvent) -> NPoint { normalize(cg: e.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero) }

    private func handleMouse(_ e: NSEvent) {
        guard let t = mediaTime(of: e) else { return }
        let down: Bool
        let button: MouseButton
        switch e.type {
        case .leftMouseDown: down = true; button = .left
        case .leftMouseUp: down = false; button = .left
        case .rightMouseDown: down = true; button = .right
        case .rightMouseUp: down = false; button = .right
        case .otherMouseDown: down = true; button = .other
        default: down = false; button = .other
        }
        let ev = ClickEvent(t: t, p: point(of: e), button: button, down: down)
        lock.lock(); events.clicks.append(ev); lock.unlock()
    }

    private func handleScroll(_ e: NSEvent) {
        guard let t = mediaTime(of: e), e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0 else { return }
        let ev = ScrollEvent(t: t, p: point(of: e), dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY))
        lock.lock(); events.scrolls.append(ev); lock.unlock()
    }

    private func handleKey(_ e: NSEvent) {
        guard !e.isARepeat, let t = mediaTime(of: e) else { return }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let ev = KeyEvent(t: t, keyCode: e.keyCode, modifiers: mods, characters: e.charactersIgnoringModifiers ?? "")
        lock.lock(); events.keys.append(ev); lock.unlock()
    }
}
