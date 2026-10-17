import Foundation
import CoreGraphics

/// The visible part of the canvas: a normalized rect (top-left origin) of side 1/scale.
public struct Viewport: Equatable, Sendable {
    public var rect: CGRect
    public static let identity = Viewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    public var scale: Double { 1 / max(Double(rect.width), 0.0001) }

    /// Viewport magnified `scale`× around `center`, shifted to stay inside the canvas.
    public static func make(scale: Double, center: NPoint) -> Viewport {
        let s = max(scale, 1)
        let w = 1 / s
        let x = min(max(center.x - w / 2, 0), 1 - w)
        let y = min(max(center.y - w / 2, 0), 1 - w)
        return Viewport(rect: CGRect(x: x, y: y, width: w, height: w))
    }

    static func lerp(_ a: Viewport, _ b: Viewport, _ t: Double) -> Viewport {
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(t) }
        return Viewport(rect: CGRect(x: l(a.rect.minX, b.rect.minX), y: l(a.rect.minY, b.rect.minY),
                                     width: l(a.rect.width, b.rect.width), height: l(a.rect.height, b.rect.height)))
    }
}

/// Evaluates the camera (zoom viewport) at any time from the zoom segments (FLZoom → ZoomViewportState).
///
/// Each segment zooms in over the first `transition` seconds and out over the last ones. Segments separated
/// by less than `mergeGap` hand over directly without zooming out in between.
public struct ZoomPlanner: Sendable {
    public let segments: [ZoomSegment]
    public let transition: Double
    public let easing: ZoomEasing
    public static let mergeGap = 0.6

    private struct Keyframe { var time: Double; var target: Int?; var duration: Double }
    private let keyframes: [Keyframe]

    public init(segments: [ZoomSegment], animation: ZoomAnimationStyle, easing: ZoomEasing) {
        let segs = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        self.segments = segs
        self.transition = animation.duration
        self.easing = easing
        var kf: [Keyframe] = []
        for (i, s) in segs.enumerated() {
            let d = min(animation.duration, s.duration / 2)
            kf.append(Keyframe(time: s.start, target: i, duration: d))
            let next = i + 1 < segs.count ? segs[i + 1] : nil
            if next.map({ $0.start - s.end >= Self.mergeGap }) ?? true {
                kf.append(Keyframe(time: s.end - d, target: nil, duration: d))
            }
        }
        keyframes = kf
    }

    /// `focus(segment, t)` returns the canvas-normalized point a segment looks at (its manual focus, or the
    /// smoothed cursor for follow-cursor segments), already mapped into canvas space by the caller.
    public func viewport(at t: Double, focus: (ZoomSegment, Double) -> NPoint) -> Viewport {
        func target(_ i: Int?, _ time: Double) -> Viewport {
            guard let i else { return .identity }
            let s = segments[i]
            return .make(scale: s.level, center: focus(s, time))
        }
        var from = Viewport.identity
        var active: Keyframe?
        func eval(_ k: Keyframe?, _ from: Viewport, _ time: Double) -> Viewport {
            guard let k else { return .identity }
            let to = target(k.target, time)
            guard k.duration > 0 else { return to }
            let p = Easing.apply(easing, (time - k.time) / k.duration)
            return .lerp(from, to, p)
        }
        for k in keyframes {
            if k.time > t { break }
            from = eval(active, from, k.time)
            active = k
        }
        return eval(active, from, t)
    }
}

/// Generates zoom segments from click activity (FLSmartZoomAnalyzer).
public struct SmartZoomAnalyzer {
    public var normalZoom = 1.8
    public var highIntensityZoom = 2.4
    /// Zoom starts this long before the first click of a cluster.
    public var clickLeadIn = 0.7
    /// …and ends this long after its last click.
    public var zoomTrailAfter = 1.6
    public var minZoomDuration = 1.6
    public var maxZoomDuration = 9.0
    /// Clicks closer than this (seconds) and…
    public var neighborTimeRadius = 3.0
    /// …within this fraction of the frame belong to one cluster.
    public var neighborSpaceFraction = 0.28
    /// Consecutive zooms closer than this are merged.
    public var mergeGapThreshold = 1.0
    /// Clusters whose clicks spread wider than this follow the cursor instead of a fixed point.
    public var followSpread = 0.18

    public init() {}

    public func analyze(clicks: [ClickEvent], duration: Double, defaultLevel: Double? = nil) -> [ZoomSegment] {
        let downs = clicks.filter { $0.down }.sorted { $0.t < $1.t }
        guard !downs.isEmpty, duration > 0 else { return [] }

        // 1. Cluster clicks that are close in both time and space.
        var clusters: [[ClickEvent]] = []
        for c in downs {
            if var last = clusters.last, let prev = last.last, c.t - prev.t <= neighborTimeRadius,
               Self.centroid(last).distance(to: c.p) <= neighborSpaceFraction {
                last.append(c)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([c])
            }
        }

        // 2. One zoom per cluster (long clusters are chopped at maxZoomDuration).
        var zooms: [ZoomSegment] = []
        for cluster in clusters {
            let start = max(0, cluster[0].t - clickLeadIn)
            var end = min(duration, cluster[cluster.count - 1].t + zoomTrailAfter)
            if end - start < minZoomDuration { end = min(duration, start + minZoomDuration) }
            let spread = cluster.map { $0.p.distance(to: Self.centroid(cluster)) }.max() ?? 0
            let level = defaultLevel ?? (cluster.count >= 3 && spread < 0.08 ? highIntensityZoom : normalZoom)
            let mode: ZoomMode = spread > followSpread ? .followCursor : .manual
            var s = start
            while s < end - 0.01 {
                let e = min(end, s + maxZoomDuration)
                zooms.append(ZoomSegment(start: s, end: e, level: level, mode: mode, focus: Self.centroid(cluster).clamped))
                s = e
            }
        }

        // 3. Merge near neighbours that look at the same place; otherwise resolve overlaps.
        var merged: [ZoomSegment] = []
        for z in zooms {
            guard var last = merged.last else { merged.append(z); continue }
            let gap = z.start - last.end
            if gap < mergeGapThreshold && last.focus.distance(to: z.focus) <= neighborSpaceFraction
                && z.end - last.start <= maxZoomDuration {
                last.end = max(last.end, z.end)
                last.level = max(last.level, z.level)
                if last.mode != z.mode { last.mode = .followCursor }
                merged[merged.count - 1] = last
            } else {
                if gap < 0 { merged[merged.count - 1].end = z.start }
                merged.append(z)
            }
        }
        return merged.filter { $0.duration >= LaneMath.minimumDuration }
    }

    static func centroid(_ c: [ClickEvent]) -> NPoint {
        guard !c.isEmpty else { return .center }
        return NPoint(x: c.map(\.p.x).reduce(0, +) / Double(c.count), y: c.map(\.p.y).reduce(0, +) / Double(c.count))
    }
}
