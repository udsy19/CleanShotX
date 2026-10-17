import Foundation
import CoreGraphics

/// Builds arrow outlines for every `ArrowStyle`. Output is geometry only so it can be unit-tested and
/// drawn by the renderer (strokes with round caps + filled heads, composited in one transparency layer).
public enum ArrowGenerator {
    public struct Geometry {
        /// Paths to stroke with `width` (round caps/joins).
        public var strokes: [(path: CGPath, width: CGFloat)] = []
        /// Closed paths to fill.
        public var fills: [CGPath] = []
        /// Head polygons (tip first) — exposed for tests.
        public var heads: [[CGPoint]] = []
    }

    public static func headLength(for width: CGFloat) -> CGFloat { max(12, width * 3 + 8) }

    /// - Parameters:
    ///   - tail/tip: the arrow points from `tail` to `tip`.
    ///   - control: quadratic control point (curved style only).
    public static func geometry(tail: CGPoint, tip: CGPoint, control: CGPoint?, width w: CGFloat, style: ArrowStyle) -> Geometry {
        var g = Geometry()
        let length = Geo.dist(tail, tip)
        guard length > 0.5 else { return g }
        var headLen = min(headLength(for: w), length * (style == .double ? 0.4 : 0.6))
        if style == .slim { headLen = min(max(10, w * 2.5 + 6), length * 0.6) }
        let headHalf = headLen * (style == .fancy ? 0.6 : 0.55)

        switch style {
        case .standard, .double:
            let u = unit(tail, tip)
            let head = triangle(tip: tip, dir: u, length: headLen, half: headHalf)
            g.heads.append(head); g.fills.append(polygon(head))
            var shaftStart = tail
            if style == .double {
                let back = triangle(tip: tail, dir: CGVector(dx: -u.dx, dy: -u.dy), length: headLen, half: headHalf)
                g.heads.append(back); g.fills.append(polygon(back))
                shaftStart = Geo.add(tail, CGVector(dx: u.dx * headLen * 0.8, dy: u.dy * headLen * 0.8))
            }
            let shaftEnd = Geo.add(tip, CGVector(dx: -u.dx * headLen * 0.8, dy: -u.dy * headLen * 0.8))
            g.strokes.append((line(shaftStart, shaftEnd), w))

        case .slim:
            let u = unit(tail, tip)
            let n = CGVector(dx: -u.dy, dy: u.dx)
            let base = Geo.add(tip, CGVector(dx: -u.dx * headLen, dy: -u.dy * headLen))
            let left = Geo.add(base, CGVector(dx: n.dx * headHalf, dy: n.dy * headHalf))
            let right = Geo.add(base, CGVector(dx: -n.dx * headHalf, dy: -n.dy * headHalf))
            let chevron = CGMutablePath()
            chevron.move(to: left); chevron.addLine(to: tip); chevron.addLine(to: right)
            let sw = max(1.5, w * 0.7)
            g.heads.append([tip, left, right])
            g.strokes.append((line(tail, tip), sw))
            g.strokes.append((chevron, sw))

        case .fancy:
            // Tapered body: hairline at the tail, swelling towards the head, with swept-back barbs.
            let u = unit(tail, tip)
            let n = CGVector(dx: -u.dy, dy: u.dx)
            let base = Geo.add(tip, CGVector(dx: -u.dx * headLen * 0.75, dy: -u.dy * headLen * 0.75))
            let barbBase = Geo.add(tip, CGVector(dx: -u.dx * headLen, dy: -u.dy * headLen))
            let body = max(1.5, w * 0.75)
            let tailHalf = max(0.5, w * 0.12)
            func off(_ p: CGPoint, _ k: CGFloat) -> CGPoint { Geo.add(p, CGVector(dx: n.dx * k, dy: n.dy * k)) }
            let pts = [off(tail, tailHalf), off(base, body), off(barbBase, headHalf), tip,
                       off(barbBase, -headHalf), off(base, -body), off(tail, -tailHalf)]
            g.heads.append([tip, off(barbBase, headHalf), off(barbBase, -headHalf)])
            g.fills.append(polygon(pts))

        case .curved:
            let c = control ?? Geo.mid(tail, tip)
            // Head direction follows the curve's tangent at the tip.
            var tan = Geo.quadTangent(tail, c, tip, 1)
            if hypot(tan.dx, tan.dy) < 0.001 { tan = Geo.sub(tip, tail) }
            let tl = hypot(tan.dx, tan.dy)
            let u = CGVector(dx: tan.dx / tl, dy: tan.dy / tl)
            let head = triangle(tip: tip, dir: u, length: headLen, half: headHalf)
            g.heads.append(head); g.fills.append(polygon(head))
            // Trim the shaft where it enters the head (binary search on distance to the tip).
            let target = headLen * 0.8
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<24 {
                let m = (lo + hi) / 2
                if Geo.dist(Geo.quadPoint(tail, c, tip, m), tip) > target { lo = m } else { hi = m }
            }
            let (pc, pe) = Geo.quadPrefix(tail, c, tip, lo)
            let p = CGMutablePath()
            p.move(to: tail); p.addQuadCurve(to: pe, control: pc)
            g.strokes.append((p, w))
        }
        return g
    }

    // MARK: Helpers

    private static func unit(_ a: CGPoint, _ b: CGPoint) -> CGVector {
        let d = Geo.dist(a, b)
        return d > 0 ? CGVector(dx: (b.x - a.x) / d, dy: (b.y - a.y) / d) : CGVector(dx: 1, dy: 0)
    }

    /// Head with a slightly concave back so it reads as an arrowhead rather than a flat triangle.
    private static func triangle(tip: CGPoint, dir u: CGVector, length: CGFloat, half: CGFloat) -> [CGPoint] {
        let n = CGVector(dx: -u.dy, dy: u.dx)
        let base = Geo.add(tip, CGVector(dx: -u.dx * length, dy: -u.dy * length))
        let notch = Geo.add(tip, CGVector(dx: -u.dx * length * 0.82, dy: -u.dy * length * 0.82))
        return [tip,
                Geo.add(base, CGVector(dx: n.dx * half, dy: n.dy * half)),
                notch,
                Geo.add(base, CGVector(dx: -n.dx * half, dy: -n.dy * half))]
    }

    private static func polygon(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts)
        p.closeSubpath()
        return p
    }

    private static func line(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let p = CGMutablePath()
        p.move(to: a); p.addLine(to: b)
        return p
    }
}

/// Freehand smoothing: point thinning + Chaikin corner cutting + Catmull-Rom → cubic Bézier.
public enum PathSmoothing {
    /// Drops samples closer than `minDistance` to the previous kept sample (always keeps the last).
    public static func thinned(_ pts: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst().dropLast() where Geo.dist(p, out.last!) >= minDistance { out.append(p) }
        out.append(pts.last!)
        return out
    }

    /// One Chaikin iteration keeps the endpoints and replaces each inner segment with ¼/¾ points.
    public static func chaikin(_ pts: [CGPoint], iterations: Int = 1) -> [CGPoint] {
        guard pts.count > 2, iterations > 0 else { return pts }
        var cur = pts
        for _ in 0..<iterations {
            var next = [cur[0]]
            for i in 0..<(cur.count - 1) {
                let a = cur[i], b = cur[i + 1]
                next.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                next.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            next.append(cur[cur.count - 1])
            cur = next
        }
        return cur
    }

    /// Centripetal-free (uniform) Catmull-Rom spline through every point, as cubic Bézier segments.
    public static func catmullRomPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            if pts.count == 2 { path.addLine(to: pts[1]) } else { path.addLine(to: first) }
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// The path drawn for a freehand stroke.
    public static func path(_ pts: [CGPoint], smooth: Bool) -> CGPath {
        guard smooth, pts.count > 3 else {
            let p = CGMutablePath()
            guard let f = pts.first else { return p }
            p.move(to: f)
            if pts.count == 1 { p.addLine(to: f) } else { p.addLines(between: pts) }
            return p
        }
        return catmullRomPath(chaikin(thinned(pts, minDistance: 2), iterations: 1))
    }
}
