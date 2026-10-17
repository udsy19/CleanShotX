import Foundation

/// Easing curves used for zoom / camera transitions.
public enum Easing {
    public static func apply(_ e: ZoomEasing, _ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        switch e {
        case .linear: return t
        case .smooth: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // ease-in-out cubic
        case .snappy: return 1 - pow(1 - t, 4)                                        // ease-out quart
        }
    }
    public static func smoothstep(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
}

/// The 1€ filter (Casiez et al.) — adaptive low-pass: smooth when slow, responsive when fast.
public struct OneEuroFilter {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double
    private var lastValue: Double?
    private var lastDerivative = 0.0
    private var lastTime: Double?

    public init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1) {
        self.minCutoff = minCutoff; self.beta = beta; self.derivativeCutoff = derivativeCutoff
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    public mutating func filter(_ x: Double, at t: Double) -> Double {
        guard let prev = lastValue, let pt = lastTime, t > pt else {
            if lastValue == nil { lastValue = x; lastTime = t }
            return lastValue ?? x
        }
        let dt = t - pt
        let dx = (x - prev) / dt
        let ad = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let edx = lastDerivative + ad * (dx - lastDerivative)
        let cutoff = minCutoff + beta * abs(edx)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let v = prev + a * (x - prev)
        lastValue = v; lastDerivative = edx; lastTime = t
        return v
    }
}

/// Precomputed cursor motion for fast lookups at render time. Immutable and thread-safe.
public final class CursorTrack: @unchecked Sendable {
    public let raw: [CursorSample]
    /// `raw` run through a 1€ filter for the chosen smoothing amount.
    public let smoothed: [CursorSample]
    /// Heavily smoothed path for follow-cursor camera panning.
    public let camera: [CursorSample]
    /// Times at which the cursor moved, a button was pressed or the wheel scrolled (sorted).
    private let activity: [Double]
    /// Times of "typing" key presses (sorted).
    private let typing: [Double]
    /// (downTime, upTime) press intervals of the primary button.
    private let presses: [(Double, Double)]
    /// Left/right mouse-down events (sorted).
    public let clicks: [ClickEvent]
    private let rawTimes: [Double]
    private let clickTimes: [Double]

    public static let idleDelay = 1.5
    public static let fade = 0.25

    public init(events: StudioEvents, smoothing: Double) {
        let raw = events.cursor.sorted { $0.t < $1.t }
        self.raw = raw
        self.smoothed = Self.smooth(raw, amount: smoothing)
        self.camera = Self.smooth(raw, amount: 1, extraCutoffScale: 0.35)
        var act: [Double] = []
        for i in 1..<max(raw.count, 1) where raw[i].p.distance(to: raw[i - 1].p) > 0.0008 { act.append(raw[i].t) }
        act += events.clicks.map(\.t) + events.scrolls.map(\.t)
        activity = act.sorted()
        typing = events.keys.filter { KeystrokeFormatter.isTyping($0) }.map(\.t).sorted()
        clicks = events.clicks.filter { $0.down }.sorted { $0.t < $1.t }
        rawTimes = raw.map(\.t)
        clickTimes = clicks.map(\.t)
        var p: [(Double, Double)] = []
        var open: Double?
        for c in events.clicks.sorted(by: { $0.t < $1.t }) where c.button == .left {
            if c.down { open = c.t } else if let o = open { p.append((o, c.t)); open = nil }
        }
        if let o = open { p.append((o, o + 0.25)) }
        presses = p
    }

    /// Runs samples through a 1€ filter. `amount` 0 returns the raw samples.
    public static func smooth(_ samples: [CursorSample], amount: Double, extraCutoffScale: Double = 1) -> [CursorSample] {
        let a = min(max(amount, 0), 1)
        guard a > 0.001, samples.count > 2 else { return samples }
        // amount 0→1 maps the base cutoff from 12 Hz (barely filtered) down to 0.6 Hz (very smooth).
        let minCutoff = (12 * pow(0.05, a)) * extraCutoffScale
        let beta = 0.8 * (1 - a) + 0.05
        var fx = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        var fy = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        return samples.map { s in
            CursorSample(t: s.t, p: NPoint(x: fx.filter(s.p.x, at: s.t), y: fy.filter(s.p.y, at: s.t)), kind: s.kind)
        }
    }

    /// Linear interpolation into a sorted sample array.
    public static func position(in samples: [CursorSample], at t: Double) -> NPoint? {
        guard let first = samples.first else { return nil }
        if t <= first.t { return first.p }
        guard let last = samples.last, t < last.t else { return samples.last?.p }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let span = b.t - a.t
        return span > 0 ? NPoint.lerp(a.p, b.p, (t - a.t) / span) : b.p
    }

    public func position(at t: Double) -> NPoint? { Self.position(in: smoothed, at: t) }
    public func cameraPosition(at t: Double) -> NPoint? { Self.position(in: camera, at: t) }

    public func kind(at t: Double) -> CursorKind {
        guard let i = Self.lastIndex(in: rawTimes, atOrBefore: t) else { return raw.first?.kind ?? .arrow }
        return raw[i].kind
    }

    static func lastIndex(in sorted: [Double], atOrBefore t: Double) -> Int? {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// Cursor opacity 0…1 honoring "hide when not moving" / "hide when typing".
    public func opacity(at t: Double, hideWhenIdle: Bool, hideWhenTyping: Bool) -> Double {
        var alpha = 1.0
        let lastAct = Self.lastIndex(in: activity, atOrBefore: t).map { activity[$0] }
        if hideWhenIdle {
            // Fade out after the idle delay; fade back in just before activity resumes.
            let since = lastAct.map { t - $0 } ?? (t + Self.idleDelay)
            let out = 1 - Easing.smoothstep((since - Self.idleDelay) / Self.fade)
            let nextIdx = (Self.lastIndex(in: activity, atOrBefore: t).map { $0 + 1 }) ?? 0
            let until = nextIdx < activity.count ? activity[nextIdx] - t : .infinity
            let incoming = 1 - Easing.smoothstep(until / 0.12)
            alpha = min(alpha, max(out, incoming))
        }
        if hideWhenTyping, let k = Self.lastIndex(in: typing, atOrBefore: t).map({ typing[$0] }) {
            if lastAct.map({ $0 < k }) ?? true {
                alpha = min(alpha, 1 - Easing.smoothstep((t - k) / 0.15))
            }
        }
        return alpha
    }

    /// 0 = released, 1 = fully pressed (eased over 80 ms).
    public func pressAmount(at t: Double) -> Double {
        for (d, u) in presses where t >= d - 0.001 && t <= u + 0.08 {
            if t <= u { return Easing.smoothstep((t - d) / 0.08) }
            return 1 - Easing.smoothstep((t - u) / 0.08)
        }
        return 0
    }

    public static let rippleDuration = 0.55

    /// Active ripples at `t`: (position, progress 0…1).
    public func ripples(at t: Double) -> [(NPoint, Double)] {
        guard let hi = Self.lastIndex(in: clickTimes, atOrBefore: t) else { return [] }
        var out: [(NPoint, Double)] = []
        var i = hi
        while i >= 0, t - clicks[i].t <= Self.rippleDuration {
            out.append((clicks[i].p, (t - clicks[i].t) / Self.rippleDuration))
            i -= 1
        }
        return out
    }
}

/// Keystroke labels shown over the video.
public enum KeystrokeFormatter {
    // NSEvent.ModifierFlags raw values (kept numeric so this file stays AppKit-free).
    static let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20

    static let special: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func isShortcut(_ k: KeyEvent) -> Bool { k.modifiers & (command | control | option) != 0 }
    /// Plain text entry (no ⌘/⌃/⌥, not a navigation key) — hides the cursor when "hide when typing" is on.
    public static func isTyping(_ k: KeyEvent) -> Bool {
        !isShortcut(k) && (special[k.keyCode] == nil || k.keyCode == 49 || k.keyCode == 51)
    }

    /// "⌘⇧S", "⌥←", "A".
    public static func label(_ k: KeyEvent) -> String {
        var s = ""
        if k.modifiers & control != 0 { s += "⌃" }
        if k.modifiers & option != 0 { s += "⌥" }
        if k.modifiers & shift != 0 && (isShortcut(k) || special[k.keyCode] != nil) { s += "⇧" }
        if k.modifiers & command != 0 { s += "⌘" }
        let key = special[k.keyCode] ?? k.characters.uppercased()
        return s + key
    }

    /// The character a typing key contributes to a running text label.
    static func typed(_ k: KeyEvent) -> String {
        if k.keyCode == 49 { return " " }
        if k.keyCode == 51 { return "⌫" }
        return k.modifiers & shift != 0 ? k.characters.uppercased() : k.characters
    }
}

/// Precomputed keystroke overlay: when each label is visible and with what text.
public struct KeystrokeTimeline: Sendable {
    public struct Entry: Sendable { public var start: Double; public var end: Double; public var steps: [(Double, String)] }
    public let entries: [Entry]
    public static let hold = 1.2
    public static let joinGap = 0.9
    public static let maxTypedLength = 24

    public init(keys: [KeyEvent], displayAll: Bool) {
        var entries: [Entry] = []
        for k in keys.sorted(by: { $0.t < $1.t }) {
            let shortcut = KeystrokeFormatter.isShortcut(k)
            if !displayAll && !shortcut { continue }
            if displayAll && !shortcut && KeystrokeFormatter.isTyping(k),
               var last = entries.last, last.steps.last.map({ k.t - $0.0 <= Self.joinGap }) ?? false,
               let prevText = last.steps.last?.1, !prevText.contains("⌘") && !prevText.contains("⌃") && !prevText.contains("⌥") {
                // Extend the running text label.
                var text = prevText + KeystrokeFormatter.typed(k)
                if text.count > Self.maxTypedLength { text = String(text.suffix(Self.maxTypedLength)) }
                last.steps.append((k.t, text))
                last.end = k.t + Self.hold
                entries[entries.count - 1] = last
                continue
            }
            let text = (displayAll && KeystrokeFormatter.isTyping(k)) ? KeystrokeFormatter.typed(k) : KeystrokeFormatter.label(k)
            // A new label replaces the previous one immediately.
            if !entries.isEmpty, entries[entries.count - 1].end > k.t { entries[entries.count - 1].end = k.t }
            entries.append(Entry(start: k.t, end: k.t + Self.hold, steps: [(k.t, text)]))
        }
        self.entries = entries
    }

    /// The label at `t` with its opacity.
    public func label(at t: Double) -> (text: String, alpha: Double)? {
        guard let e = entries.last(where: { $0.start <= t && t < $0.end }) else { return nil }
        let text = e.steps.last { $0.0 <= t }?.1 ?? e.steps[0].1
        let fadeIn = Easing.smoothstep((t - e.start) / 0.08)
        let fadeOut = 1 - Easing.smoothstep((t - (e.end - 0.25)) / 0.25)
        return (text, min(fadeIn, fadeOut))
    }
}
