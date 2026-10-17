import Foundation
import CoreGraphics

/// Pure geometry helpers used by tools, hit testing, crop and snapping. Document space is y-down.
public enum Geo {
    public static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    public static func add(_ p: CGPoint, _ d: CGVector) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
    public static func sub(_ a: CGPoint, _ b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
    public static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    public static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    public static func bounds(of points: [CGPoint]) -> CGRect {
        guard let f = points.first else { return .zero }
        var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Modifier constraints

    /// ⇧ for lines: snap the direction to the nearest 45°.
    public static func constrainAngle(_ p: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = p.x - origin.x, dy = p.y - origin.y
        let len = hypot(dx, dy)
        guard len > 0 else { return p }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: origin.x + cos(angle) * len, y: origin.y + sin(angle) * len)
    }

    /// Rect drawn from `anchor` to `p` with ⇧ (square) and ⌥ (anchor is the centre) modifiers.
    public static func dragRect(from anchor: CGPoint, to p: CGPoint, square: Bool, fromCenter: Bool) -> (CGPoint, CGPoint) {
        var dx = p.x - anchor.x, dy = p.y - anchor.y
        if square {
            let s = max(abs(dx), abs(dy))
            dx = dx < 0 ? -s : s
            dy = dy < 0 ? -s : s
        }
        if fromCenter {
            return (CGPoint(x: anchor.x - dx, y: anchor.y - dy), CGPoint(x: anchor.x + dx, y: anchor.y + dy))
        }
        return (anchor, CGPoint(x: anchor.x + dx, y: anchor.y + dy))
    }

    // MARK: Distances

    public static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        return dist(p, CGPoint(x: a.x + t * abx, y: a.y + t * aby))
    }

    public static func distance(_ p: CGPoint, polyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        if pts.count == 1 { return dist(p, first) }
        var best = CGFloat.infinity
        for i in 1..<pts.count { best = min(best, distance(p, segment: pts[i - 1], pts[i])) }
        return best
    }

    public static func distanceToRectBorder(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        return distance(p, polyline: corners + [corners[0]])
    }

    /// Approximate distance to an ellipse outline (normalised radial distance scaled back to points).
    public static func distanceToEllipse(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let rx = r.width / 2, ry = r.height / 2
        guard rx > 0.5, ry > 0.5 else { return distanceToRectBorder(p, r) }
        let dx = p.x - r.midX, dy = p.y - r.midY
        let angle = atan2(dy / ry, dx / rx)
        let onEllipse = CGPoint(x: r.midX + rx * cos(angle), y: r.midY + ry * sin(angle))
        return dist(p, onEllipse)
    }

    public static func segmentIntersectsRect(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> Bool {
        if r.contains(a) || r.contains(b) { return true }
        let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        for i in 0..<4 where segmentsIntersect(a, b, c[i], c[(i + 1) % 4]) { return true }
        return false
    }

    public static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        let d1 = cross(p3, p4, p1), d2 = cross(p3, p4, p2), d3 = cross(p1, p2, p3), d4 = cross(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    // MARK: Quadratic Béziers

    public static func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
    public static func quadTangent(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGVector {
        CGVector(dx: 2 * (1 - t) * (c.x - a.x) + 2 * t * (b.x - c.x), dy: 2 * (1 - t) * (c.y - a.y) + 2 * t * (b.y - c.y))
    }
    public static func sampleQuad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, steps: Int) -> [CGPoint] {
        (0...steps).map { quadPoint(a, c, b, CGFloat($0) / CGFloat(steps)) }
    }
    public static func quadBounds(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGRect { bounds(of: sampleQuad(a, c, b, steps: 24)) }

    /// Splits a quadratic Bézier at `t` and returns the first part's control and end point (de Casteljau).
    public static func quadPrefix(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> (control: CGPoint, end: CGPoint) {
        let p01 = CGPoint(x: a.x + (c.x - a.x) * t, y: a.y + (c.y - a.y) * t)
        return (p01, quadPoint(a, c, b, t))
    }

    // MARK: Rect handles

    public enum RectHandle: CaseIterable, Hashable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        public func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .top: CGPoint(x: r.midX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .right: CGPoint(x: r.maxX, y: r.midY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            case .bottom: CGPoint(x: r.midX, y: r.maxY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            case .left: CGPoint(x: r.minX, y: r.midY)
            }
        }
        var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesMinY: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesMaxY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight }
    }

    /// Resizes `r` by dragging `handle` to `p`. The result is always standardized (dragging past the
    /// opposite edge flips). `keepAspect` preserves r's aspect ratio; `fromCenter` mirrors around the centre.
    public static func resize(_ r: CGRect, handle: RectHandle, to p: CGPoint, keepAspect: Bool, fromCenter: Bool) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        let cx = r.midX, cy = r.midY
        if handle.movesMinX { minX = p.x; if fromCenter { maxX = 2 * cx - p.x } }
        if handle.movesMaxX { maxX = p.x; if fromCenter { minX = 2 * cx - p.x } }
        if handle.movesMinY { minY = p.y; if fromCenter { maxY = 2 * cy - p.y } }
        if handle.movesMaxY { maxY = p.y; if fromCenter { minY = 2 * cy - p.y } }
        var out = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        guard keepAspect, r.width > 0, r.height > 0 else { return out }
        let aspect = r.width / r.height
        // Anchor = the edge/corner opposite to the handle (or the centre).
        let anchor: CGPoint = fromCenter ? CGPoint(x: cx, y: cy) : CGPoint(
            x: handle.movesMinX ? r.maxX : (handle.movesMaxX ? r.minX : cx),
            y: handle.movesMinY ? r.maxY : (handle.movesMaxY ? r.minY : cy))
        var w = out.width, h = out.height
        if handle.isCorner {
            if w / max(h, 0.0001) > aspect { h = w / aspect } else { w = h * aspect }
        } else if handle == .left || handle == .right {
            h = w / aspect
        } else {
            w = h * aspect
        }
        let flipX = (handle.movesMinX && p.x > anchor.x) || (handle.movesMaxX && p.x < anchor.x)
        let flipY = (handle.movesMinY && p.y > anchor.y) || (handle.movesMaxY && p.y < anchor.y)
        let x: CGFloat
        let y: CGFloat
        if fromCenter { x = cx - w / 2; y = cy - h / 2 } else {
            if handle.movesMinX { x = flipX ? anchor.x : anchor.x - w }
            else if handle.movesMaxX { x = flipX ? anchor.x - w : anchor.x }
            else { x = cx - w / 2 }
            if handle.movesMinY { y = flipY ? anchor.y : anchor.y - h }
            else if handle.movesMaxY { y = flipY ? anchor.y - h : anchor.y }
            else { y = cy - h / 2 }
        }
        out = CGRect(x: x, y: y, width: w, height: h)
        return out
    }

    /// Rounds a rect outward to the pixel grid of `scale`.
    public static func pixelAligned(_ r: CGRect, scale: CGFloat) -> CGRect {
        guard !r.isNull, !r.isInfinite else { return r }
        let s = max(scale, 1)
        let minX = floor(r.minX * s + 0.001) / s, minY = floor(r.minY * s + 0.001) / s
        let maxX = ceil(r.maxX * s - 0.001) / s, maxY = ceil(r.maxY * s - 0.001) / s
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Fits `size` with an aspect `ratio` (w/h) inside `bounds`, centred.
    public static func fit(ratio: CGFloat, in bounds: CGRect) -> CGRect {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var w = bounds.width, h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Snapping

/// Snapping of a moving rect to guide lines (other objects' edges/centres and the canvas).
public enum Snapping {
    public struct Guide: Equatable, Sendable {
        public enum Axis: Sendable { case vertical, horizontal }
        public var axis: Axis
        /// x for vertical guides, y for horizontal ones.
        public var position: CGFloat
        /// True when the guide comes from the canvas (centre/edges) rather than another object.
        public var isCanvas: Bool
    }

    public struct Result: Equatable, Sendable {
        public var offset: CGVector
        public var guides: [Guide]
    }

    /// Returns the correction to add to `moving` so one of its x-features (minX, midX, maxX) and one of its
    /// y-features aligns with the closest target feature within `threshold`.
    public static func snap(_ moving: CGRect, targets: [CGRect], canvas: CGRect?, threshold: CGFloat) -> Result {
        var xs: [(CGFloat, Bool)] = [], ys: [(CGFloat, Bool)] = []
        for t in targets {
            xs += [(t.minX, false), (t.midX, false), (t.maxX, false)]
            ys += [(t.minY, false), (t.midY, false), (t.maxY, false)]
        }
        if let c = canvas {
            xs += [(c.minX, true), (c.midX, true), (c.maxX, true)]
            ys += [(c.minY, true), (c.midY, true), (c.maxY, true)]
        }
        func best(_ features: [CGFloat], _ candidates: [(CGFloat, Bool)]) -> (CGFloat, CGFloat, Bool)? {
            var result: (CGFloat, CGFloat, Bool)?
            for f in features {
                for (c, canvas) in candidates {
                    let d = c - f
                    if abs(d) <= threshold && (result == nil || abs(d) < abs(result!.0)) { result = (d, c, canvas) }
                }
            }
            return result
        }
        var offset = CGVector.zero
        var guides: [Guide] = []
        if let (d, c, isCanvas) = best([moving.minX, moving.midX, moving.maxX], xs) {
            offset.dx = d; guides.append(Guide(axis: .vertical, position: c, isCanvas: isCanvas))
        }
        if let (d, c, isCanvas) = best([moving.minY, moving.midY, moving.maxY], ys) {
            offset.dy = d; guides.append(Guide(axis: .horizontal, position: c, isCanvas: isCanvas))
        }
        return Result(offset: offset, guides: guides)
    }

    /// Snaps a single point (crop handles) to the given x/y lines.
    public static func snap(_ p: CGPoint, xs: [CGFloat], ys: [CGFloat], threshold: CGFloat) -> CGPoint {
        var out = p
        if let x = xs.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(x - p.x) <= threshold { out.x = x }
        if let y = ys.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(y - p.y) <= threshold { out.y = y }
        return out
    }
}
