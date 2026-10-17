import CoreGraphics
import Foundation

// Pure selection math shared by the overlay, All-In-One controls and self-tests.
// Every rect is in global Cocoa coordinates (origin bottom-left, y grows upward).

/// Aspect-ratio constraint for the selection (All-In-One "Aspect ratio" menu).
public enum AspectRatio: Hashable, Sendable {
    case freeform
    /// Width : height.
    case ratio(Double, Double)
    /// Fixed size in points.
    case size(Double, Double)

    public static let ratios: [AspectRatio] = [.freeform, .ratio(1, 1), .ratio(4, 3), .ratio(3, 2), .ratio(16, 9), .ratio(16, 10), .ratio(9, 16)]
    public static let sizes: [AspectRatio] = [.size(640, 480), .size(800, 600), .size(1024, 768), .size(1280, 720),
                                              .size(1280, 800), .size(1440, 900), .size(1920, 1080), .size(2560, 1440)]

    /// Width / height, nil for freeform.
    public var value: CGFloat? {
        switch self {
        case .freeform: nil
        case let .ratio(w, h), let .size(w, h): h > 0 ? CGFloat(w / h) : nil
        }
    }

    public var fixedSize: CGSize? {
        if case let .size(w, h) = self { return CGSize(width: w, height: h) }
        return nil
    }

    public var title: String {
        switch self {
        case .freeform: "Freeform"
        case let .ratio(w, h): "\(Int(w)):\(Int(h))"
        case let .size(w, h): "\(Int(w)) × \(Int(h))"
        }
    }

    /// Stable string for persistence ("free", "r16:9", "s1280x720").
    public var storageString: String {
        switch self {
        case .freeform: "free"
        case let .ratio(w, h): "r\(Int(w)):\(Int(h))"
        case let .size(w, h): "s\(Int(w))x\(Int(h))"
        }
    }

    public init?(storageString s: String) {
        if s == "free" { self = .freeform; return }
        guard let kind = s.first else { return nil }
        let parts = s.dropFirst().split(whereSeparator: { $0 == ":" || $0 == "x" }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        switch kind {
        case "r": self = .ratio(parts[0], parts[1])
        case "s": self = .size(parts[0], parts[1])
        default: return nil
        }
    }
}

/// The eight resize handles of an adjustable selection.
public enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesMinY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var movesMaxY: Bool { self == .topLeft || self == .top || self == .topRight }
    var isCorner: Bool { (movesMinX || movesMaxX) && (movesMinY || movesMaxY) }

    /// Location of the handle on `r`.
    public func point(in r: CGRect) -> CGPoint {
        let x = movesMinX ? r.minX : movesMaxX ? r.maxX : r.midX
        let y = movesMinY ? r.minY : movesMaxY ? r.maxY : r.midY
        return CGPoint(x: x, y: y)
    }
}

public enum SelectionGeometry {

    /// Distance below which a mouse-down/up pair counts as a click rather than a drag.
    public static let clickThreshold: CGFloat = 3
    /// Snapping distance in points.
    public static let snapThreshold: CGFloat = 8

    // MARK: Creating

    /// Rect spanned by a drag from `anchor` to `current`.
    /// - `square`: forces 1:1 (Shift). `fromCenter`: `anchor` is the center (Option). `ratio`: width/height lock.
    public static func rect(from anchor: CGPoint, to current: CGPoint, square: Bool = false,
                            fromCenter: Bool = false, ratio: CGFloat? = nil) -> CGRect {
        var dx = current.x - anchor.x, dy = current.y - anchor.y
        if let r = square ? 1 : ratio, r > 0 {
            let w = abs(dx), h = abs(dy)
            if w >= h * r { dy = (dy < 0 ? -1 : 1) * w / r } else { dx = (dx < 0 ? -1 : 1) * h * r }
        }
        if fromCenter {
            return CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
    }

    // MARK: Resizing

    /// Resizes `start` by dragging `handle` to `point`. The opposite edge stays fixed (or the center with
    /// `fromCenter`); dragging past it flips the rect. `ratio` keeps width/height.
    public static func resize(_ start: CGRect, handle: SelectionHandle, to point: CGPoint,
                              ratio: CGFloat? = nil, fromCenter: Bool = false) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        let c = CGPoint(x: start.midX, y: start.midY)
        if handle.movesMinX { minX = point.x; if fromCenter { maxX = 2 * c.x - point.x } }
        if handle.movesMaxX { maxX = point.x; if fromCenter { minX = 2 * c.x - point.x } }
        if handle.movesMinY { minY = point.y; if fromCenter { maxY = 2 * c.y - point.y } }
        if handle.movesMaxY { maxY = point.y; if fromCenter { minY = 2 * c.y - point.y } }
        var r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        guard let ratio, ratio > 0 else { return r }

        // Ratio lock: derive the dependent dimension, keeping the fixed anchor in place.
        let horizontal = handle.movesMinX || handle.movesMaxX
        let vertical = handle.movesMinY || handle.movesMaxY
        var w = r.width, h = r.height
        if horizontal && vertical { if w >= h * ratio { h = w / ratio } else { w = h * ratio } }
        else if horizontal { h = w / ratio }
        else { w = h * ratio }

        if fromCenter { return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h) }
        // Horizontal anchor
        let flippedX = handle.movesMinX ? point.x > start.maxX : point.x < start.minX
        let flippedY = handle.movesMinY ? point.y > start.maxY : point.y < start.minY
        let x: CGFloat
        if handle.movesMinX { x = flippedX ? start.maxX : start.maxX - w }
        else if handle.movesMaxX { x = flippedX ? start.minX - w : start.minX }
        else { x = start.midX - w / 2 }
        let y: CGFloat
        if handle.movesMinY { y = flippedY ? start.maxY : start.maxY - h }
        else if handle.movesMaxY { y = flippedY ? start.minY - h : start.minY }
        else { y = start.midY - h / 2 }
        r = CGRect(x: x, y: y, width: w, height: h)
        return r
    }

    /// Fits `r` to `ratio` around its center, keeping the larger dimension when possible and staying in `bounds`.
    public static func applying(_ aspect: AspectRatio, to r: CGRect, within bounds: CGRect) -> CGRect {
        var out = r
        if let size = aspect.fixedSize {
            out = CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
        } else if let ratio = aspect.value {
            var w = r.width, h = r.height
            if w / max(h, 1) > ratio { w = h * ratio } else { h = w / ratio }
            out = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        }
        // Shrink proportionally when it does not fit, then move inside.
        if out.width > bounds.width || out.height > bounds.height {
            let f = min(bounds.width / out.width, bounds.height / out.height)
            out = CGRect(x: out.midX - out.width * f / 2, y: out.midY - out.height * f / 2,
                         width: out.width * f, height: out.height * f)
        }
        return clamped(out, to: bounds)
    }

    // MARK: Moving / clamping

    /// Moves `r` inside `bounds` without resizing (shrinks only when larger than `bounds`).
    public static func clamped(_ r: CGRect, to bounds: CGRect) -> CGRect {
        guard !bounds.isNull, !bounds.isEmpty else { return r }
        var out = r
        out.size.width = min(out.width, bounds.width)
        out.size.height = min(out.height, bounds.height)
        out.origin.x = min(max(out.minX, bounds.minX), bounds.maxX - out.width)
        out.origin.y = min(max(out.minY, bounds.minY), bounds.maxY - out.height)
        return out
    }

    /// Arrow-key nudge (1 pt, 10 pt with Shift); `resize` grows/shrinks from the top-left anchor instead.
    public static func nudged(_ r: CGRect, dx: CGFloat, dy: CGFloat, resize: Bool, within bounds: CGRect) -> CGRect {
        if resize {
            // Keep the top-left corner fixed (Cocoa: minX, maxY).
            let w = max(1, r.width + dx), h = max(1, r.height - dy)
            let out = CGRect(x: r.minX, y: r.maxY - h, width: w, height: h)
            return out.intersection(bounds).isNull ? r : out.intersection(bounds)
        }
        return clamped(r.offsetBy(dx: dx, dy: dy), to: bounds)
    }

    /// Rect with its top-left (Cocoa: minX, maxY) kept and a new size (from the W×H fields).
    public static func resized(_ r: CGRect, to size: CGSize, within bounds: CGRect) -> CGRect {
        let w = max(1, min(size.width, bounds.width)), h = max(1, min(size.height, bounds.height))
        return clamped(CGRect(x: r.minX, y: r.maxY - h, width: w, height: h), to: bounds)
    }

    // MARK: Snapping

    /// The candidate nearest to `value` within `threshold`, if any.
    public static func snap(_ value: CGFloat, to candidates: [CGFloat], threshold: CGFloat = snapThreshold) -> CGFloat? {
        var best: CGFloat?
        var bestDist = threshold
        for c in candidates {
            let d = abs(c - value)
            if d <= bestDist { bestDist = d; best = c }
        }
        return best
    }

    /// Snaps a point (e.g. the dragged corner) to vertical (x) and horizontal (y) guide lines.
    public static func snap(_ p: CGPoint, xs: [CGFloat], ys: [CGFloat], threshold: CGFloat = snapThreshold) -> CGPoint {
        CGPoint(x: snap(p.x, to: xs, threshold: threshold) ?? p.x, y: snap(p.y, to: ys, threshold: threshold) ?? p.y)
    }

    /// Snaps a moving rect so that whichever of its edges is closest to a guide line touches it.
    public static func snapMoving(_ r: CGRect, xs: [CGFloat], ys: [CGFloat], threshold: CGFloat = snapThreshold) -> CGRect {
        var out = r
        if let dx = bestOffset(edges: [r.minX, r.maxX], candidates: xs, threshold: threshold) { out.origin.x += dx }
        if let dy = bestOffset(edges: [r.minY, r.maxY], candidates: ys, threshold: threshold) { out.origin.y += dy }
        return out
    }

    private static func bestOffset(edges: [CGFloat], candidates: [CGFloat], threshold: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for e in edges {
            if let s = snap(e, to: candidates, threshold: threshold), abs(s - e) <= abs(best ?? .infinity) { best = s - e }
        }
        return best
    }

    // MARK: Hit-testing

    /// Handle whose square of side `size` around its point contains `p` (corners win over edges).
    public static func handle(at p: CGPoint, in r: CGRect, size: CGFloat = 12) -> SelectionHandle? {
        let ordered: [SelectionHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight, .top, .right, .bottom, .left]
        for h in ordered {
            let c = h.point(in: r)
            if abs(p.x - c.x) <= size / 2 + 2 && abs(p.y - c.y) <= size / 2 + 2 { return h }
        }
        // Edges (generous band) for larger selections.
        let band: CGFloat = 4
        guard r.insetBy(dx: -band, dy: -band).contains(p) else { return nil }
        if abs(p.x - r.minX) <= band { return .left }
        if abs(p.x - r.maxX) <= band { return .right }
        if abs(p.y - r.minY) <= band { return .bottom }
        if abs(p.y - r.maxY) <= band { return .top }
        return nil
    }

    // MARK: Pixels

    /// Pixel rect (CGImage, top-left origin) inside a full-screen image of `screenFrame` for a Cocoa rect.
    public static func pixelRect(for cocoaRect: CGRect, screenFrame: CGRect, imageSize: CGSize) -> CGRect {
        let sx = imageSize.width / max(screenFrame.width, 1), sy = imageSize.height / max(screenFrame.height, 1)
        let local = cocoaRect.intersection(screenFrame)
        guard !local.isNull else { return .null }
        return CGRect(x: (local.minX - screenFrame.minX) * sx, y: (screenFrame.maxY - local.maxY) * sy,
                      width: local.width * sx, height: local.height * sy).integral
    }

    /// Where a part covering `part` lands inside a bitmap of `whole` at `scale` (bitmap origin bottom-left).
    public static func stitchDestination(part: CGRect, whole: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (part.minX - whole.minX) * scale, y: (part.minY - whole.minY) * scale,
               width: part.width * scale, height: part.height * scale)
    }

    // MARK: Formatting

    /// "W × H" (dimension badge, size fields, menus).
    public static func dimensionString(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// "#RRGGBB" from 0…1 components.
    public static func hexString(r: Double, g: Double, b: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    // MARK: Layout helpers

    /// Image placement for wallpapers. `fill` (aspect fill, clipped) / `fit` (aspect fit) / `stretch` / `center`.
    public enum ImagePlacement: Sendable { case fill, fit, stretch, center }

    public static func placement(of image: CGSize, in canvas: CGSize, mode: ImagePlacement) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        var size: CGSize
        switch mode {
        case .stretch: return CGRect(origin: .zero, size: canvas)
        case .center: size = image
        case .fill:
            let f = max(canvas.width / image.width, canvas.height / image.height)
            size = CGSize(width: image.width * f, height: image.height * f)
        case .fit:
            let f = min(canvas.width / image.width, canvas.height / image.height)
            size = CGSize(width: image.width * f, height: image.height * f)
        }
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Frame of the dimension badge: just outside the selection corner nearest the cursor (diagonally away
    /// from the selection, like the pointer is "holding" it), flipped to the other side of the cursor when it
    /// would leave `bounds`, then clamped inside `bounds` (4 pt margin).
    public static func badgeFrame(size: CGSize, cursor: CGPoint, selection: CGRect, bounds: CGRect,
                                  offset: CGFloat = 12) -> CGRect {
        let margin: CGFloat = 4
        let right = cursor.x >= selection.midX, top = cursor.y >= selection.midY
        var x = right ? cursor.x + offset : cursor.x - offset - size.width
        var y = top ? cursor.y + offset : cursor.y - offset - size.height
        if x < bounds.minX + margin { x = cursor.x + offset } else if x + size.width > bounds.maxX - margin { x = cursor.x - offset - size.width }
        if y < bounds.minY + margin { y = cursor.y + offset } else if y + size.height > bounds.maxY - margin { y = cursor.y - offset - size.height }
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - size.width)
        y = min(max(y, bounds.minY + margin), bounds.maxY - margin - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Positions a control of `size` centered below `anchor` (gap `gap`), falling back to above it,
    /// then inside it, and keeping it within `bounds`.
    public static func placeBelow(_ size: CGSize, anchor: CGRect, bounds: CGRect, gap: CGFloat = 10) -> CGRect {
        var r = CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height, width: size.width, height: size.height)
        if r.minY < bounds.minY + 4 {
            r.origin.y = anchor.maxY + gap
            if r.maxY > bounds.maxY - 4 { r.origin.y = max(anchor.minY, bounds.minY) + gap }
        }
        r.origin.x = min(max(r.minX, bounds.minX + 4), bounds.maxX - size.width - 4)
        r.origin.y = min(max(r.minY, bounds.minY + 4), bounds.maxY - size.height - 4)
        return r
    }
}
