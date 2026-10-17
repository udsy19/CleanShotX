import Foundation
import CoreGraphics

/// Pure clip math: the edited ("output") timeline is the concatenation of `clips`, each a range of the source.
public struct ClipTimeline: Sendable {
    public var clips: [StudioClip]
    public var sourceDuration: Double
    /// Shortest clip a split/trim may produce.
    public static let minimumClipDuration = 0.1

    public init(clips: [StudioClip], sourceDuration: Double) {
        self.clips = clips.sorted { $0.start < $1.start }
        self.sourceDuration = sourceDuration
    }

    public var outputDuration: Double { clips.reduce(0) { $0 + $1.duration } }

    /// Output start time of each clip.
    public var outputStarts: [Double] {
        var acc = 0.0
        return clips.map { c in defer { acc += c.duration }; return acc }
    }

    /// Output times of every clip boundary (0, …, outputDuration).
    public var edges: [Double] {
        var e = outputStarts
        e.append(outputDuration)
        return e
    }

    /// Index of the clip playing at output time `t` (the last clip for t == outputDuration).
    public func clipIndex(atOutput t: Double) -> Int? {
        guard !clips.isEmpty else { return nil }
        var acc = 0.0
        for (i, c) in clips.enumerated() {
            if t < acc + c.duration { return i }
            acc += c.duration
        }
        return clips.count - 1
    }

    public func sourceTime(forOutput t: Double) -> Double {
        guard let i = clipIndex(atOutput: max(0, t)) else { return 0 }
        let start = outputStarts[i]
        return clips[i].start + min(max(0, t - start), clips[i].duration)
    }

    /// Output time for a source time, or nil if that moment was cut.
    public func outputTime(forSource s: Double) -> Double? {
        let starts = outputStarts
        for (i, c) in clips.enumerated() where s >= c.start - 1e-9 && s <= c.end + 1e-9 {
            return starts[i] + min(max(0, s - c.start), c.duration)
        }
        return nil
    }

    /// Output time for a source time, snapping cut moments to the next (`preferLater`) or previous kept moment.
    public func outputTimeClamped(forSource s: Double, preferLater: Bool) -> Double {
        if let t = outputTime(forSource: s) { return t }
        let starts = outputStarts
        if preferLater {
            for (i, c) in clips.enumerated() where c.start >= s { return starts[i] }
            return outputDuration
        } else {
            for (i, c) in clips.enumerated().reversed() where c.end <= s { return starts[i] + c.duration }
            return 0
        }
    }

    // MARK: Edits

    /// Splits the clip under output time `t`. Returns the id of the new right-hand clip.
    @discardableResult
    public mutating func split(atOutput t: Double) -> UUID? {
        guard let i = clipIndex(atOutput: t) else { return nil }
        let local = t - outputStarts[i]
        let c = clips[i]
        guard local >= Self.minimumClipDuration, c.duration - local >= Self.minimumClipDuration else { return nil }
        let right = StudioClip(start: c.start + local, duration: c.duration - local)
        clips[i].duration = local
        clips.insert(right, at: i + 1)
        return right.id
    }

    /// Removes a clip (cut). The last remaining clip cannot be removed.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard clips.count > 1, let i = clips.firstIndex(where: { $0.id == id }) else { return false }
        clips.remove(at: i)
        return true
    }

    /// Moves the clip's left edge to `sourceStart`, bounded by the previous clip and the minimum duration.
    public mutating func trimStart(_ id: UUID, to sourceStart: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let lower = i > 0 ? clips[i - 1].end : 0
        let end = clips[i].end
        let s = min(max(sourceStart, lower), end - Self.minimumClipDuration)
        clips[i].start = s
        clips[i].duration = end - s
    }

    /// Moves the clip's right edge to `sourceEnd`, bounded by the next clip and the recording length.
    public mutating func trimEnd(_ id: UUID, to sourceEnd: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let upper = i < clips.count - 1 ? clips[i + 1].start : sourceDuration
        let e = min(max(sourceEnd, clips[i].start + Self.minimumClipDuration), upper)
        clips[i].duration = e - clips[i].start
    }

    /// Next/previous clip edge relative to output time `t`.
    public func nextEdge(after t: Double) -> Double { edges.first { $0 > t + 1e-6 } ?? outputDuration }
    public func previousEdge(before t: Double) -> Double { edges.last { $0 < t - 1e-6 } ?? 0 }
}

/// Maps between timeline time and view x-coordinates.
public struct TimelineGeometry: Equatable, Sendable {
    public var pixelsPerSecond: Double
    public var leftMargin: Double
    public init(pixelsPerSecond: Double, leftMargin: Double = 16) {
        self.pixelsPerSecond = pixelsPerSecond; self.leftMargin = leftMargin
    }
    public func x(for t: Double) -> Double { leftMargin + t * pixelsPerSecond }
    public func time(for x: Double) -> Double { (x - leftMargin) / pixelsPerSecond }
    public func width(for duration: Double) -> Double { duration * pixelsPerSecond }

    /// Scale that fits `duration` into `width` points (minus margins).
    public static func fitting(duration: Double, width: Double, leftMargin: Double = 16, rightMargin: Double = 16) -> TimelineGeometry {
        let usable = max(50, width - leftMargin - rightMargin)
        return TimelineGeometry(pixelsPerSecond: clampScale(usable / max(duration, 0.1)), leftMargin: leftMargin)
    }
    public static let minScale = 2.0
    public static let maxScale = 1200.0
    public static func clampScale(_ s: Double) -> Double { min(max(s, minScale), maxScale) }

    /// A readable ruler step (seconds) for this scale: at least ~70pt between labels.
    public var rulerStep: Double {
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { $0 * pixelsPerSecond >= 70 } ?? 600
    }
}

/// Edits on a lane of non-overlapping time segments (zooms, camera full-screen ranges). Times are source seconds.
public protocol LaneSegment {
    var id: UUID { get }
    var start: Double { get set }
    var end: Double { get set }
}
extension ZoomSegment: LaneSegment {}
extension TimeSegment: LaneSegment {}

public enum LaneMath {
    public static let minimumDuration = 0.3

    /// Free interval around `t` (between neighbors), excluding the segment `excluding`.
    public static func freeRange<S: LaneSegment>(at t: Double, in segments: [S], duration: Double, excluding: UUID? = nil) -> ClosedRange<Double>? {
        let others = segments.filter { $0.id != excluding }.sorted { $0.start < $1.start }
        if others.contains(where: { t > $0.start && t < $0.end }) { return nil }
        let lower = others.last { $0.end <= t + 1e-9 }?.end ?? 0
        let upper = others.first { $0.start >= t - 1e-9 }?.start ?? duration
        return lower <= upper ? lower...upper : nil
    }

    /// Clamps a proposed [start,end] so it doesn't overlap neighbors; returns nil if there isn't room.
    public static func place<S: LaneSegment>(start: Double, end: Double, in segments: [S], duration: Double, excluding: UUID? = nil) -> (Double, Double)? {
        let anchor = min(max(start, 0), duration)
        guard let free = freeRange(at: anchor, in: segments, duration: duration, excluding: excluding) else { return nil }
        let s = max(start, free.lowerBound)
        let e = min(end, free.upperBound)
        guard e - s >= minimumDuration - 1e-9 else { return nil }
        return (s, e)
    }

    /// Moves a segment keeping its duration, sliding it against neighbors.
    public static func move<S: LaneSegment>(_ id: UUID, toStart newStart: Double, in segments: inout [S], duration: Double) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        let len = segments[i].end - segments[i].start
        let others = segments.filter { $0.id != id }
        // Neighbours relative to the segment's current position, so it can't jump over another segment.
        let cur = segments[i].start
        let lower = others.filter { $0.end <= cur + 1e-9 }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= segments[i].end - 1e-9 }.map(\.start).min() ?? duration
        let s = min(max(newStart, lower), max(lower, upper - len))
        segments[i].start = s
        segments[i].end = min(s + len, upper)
    }

    public static func resizeStart<S: LaneSegment>(_ id: UUID, to t: Double, in segments: inout [S]) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        let lower = segments.filter { $0.id != id && $0.end <= segments[i].start + 1e-9 }.map(\.end).max() ?? 0
        segments[i].start = min(max(t, lower), segments[i].end - minimumDuration)
    }

    public static func resizeEnd<S: LaneSegment>(_ id: UUID, to t: Double, in segments: inout [S], duration: Double) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        let upper = segments.filter { $0.id != id && $0.start >= segments[i].end - 1e-9 }.map(\.start).min() ?? duration
        segments[i].end = max(min(t, upper), segments[i].start + minimumDuration)
    }

    /// Splits the segment containing `t` into two; returns the new right part's id.
    @discardableResult
    public static func split<S: LaneSegment>(at t: Double, in segments: inout [S], makeCopy: (S) -> S) -> UUID? {
        guard let i = segments.firstIndex(where: { t > $0.start + minimumDuration - 1e-9 && t < $0.end - minimumDuration + 1e-9 }) else { return nil }
        var right = makeCopy(segments[i])
        right.start = t
        right.end = segments[i].end
        segments[i].end = t
        segments.insert(right, at: i + 1)
        return right.id
    }
}

public extension ZoomSegment {
    /// A copy with a fresh id (used by split / duplicate).
    func duplicated() -> ZoomSegment { ZoomSegment(start: start, end: end, level: level, mode: mode, focus: focus) }
}

public extension LaneMath {
    /// A copy of segment `id` placed right after it (shortened to the free space). Returns the copy's id.
    @discardableResult
    static func duplicate(_ id: UUID, in segments: inout [ZoomSegment], duration: Double) -> UUID? {
        guard let src = segments.first(where: { $0.id == id }),
              let (s, e) = place(start: src.end, end: src.end + src.duration, in: segments, duration: duration) else { return nil }
        var copy = src.duplicated()
        copy.start = s; copy.end = e
        segments.append(copy)
        segments.sort { $0.start < $1.start }
        return copy.id
    }
}

public extension Array where Element == ZoomSegment {
    mutating func applyLevelToAll(_ level: Double) { for i in indices { self[i].level = level } }
}

/// Human time formatting for the transport and ruler.
public enum TimeFormat {
    /// "1:05.3" (tenths) or "1:05".
    public static func string(_ t: Double, tenths: Bool = true) -> String {
        let t = max(0, t)
        let total = Int(t)
        let m = total / 60, s = total % 60
        if tenths { return String(format: "%d:%02d.%d", m, s, Int((t - Double(total)) * 10) % 10) }
        return String(format: "%d:%02d", m, s)
    }

    /// "00:08" — the transport and ruler style (hours roll into minutes).
    public static func clock(_ t: Double) -> String {
        let total = Int(max(0, t).rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
