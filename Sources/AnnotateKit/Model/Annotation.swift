import Foundation
import CoreGraphics
import SuperScreenshotCore

// MARK: - Style enums

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case rectangle, filledRectangle, ellipse, line, arrow, text, pen, highlighter, pixelate, spotlight, counter, image

    /// Kinds whose geometry is the rectangle spanned by `start`/`end`.
    var isRectBased: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .spotlight, .image: true
        default: false
        }
    }
    var isLineBased: Bool { self == .line || self == .arrow }
}

public enum ArrowStyle: String, Codable, CaseIterable, Sendable {
    case standard, curved, double, fancy, slim
    public var title: String {
        switch self {
        case .standard: "Standard"
        case .curved: "Curved"
        case .double: "Double-headed"
        case .fancy: "Tapered"
        case .slim: "Slim"
        }
    }
}

public enum TextStyle: String, Codable, CaseIterable, Sendable {
    case standard, outline, box, rounded, roundedBox, monospaced, monospacedBox
    public var title: String {
        switch self {
        case .standard: "Standard"
        case .outline: "Outline"
        case .box: "Box"
        case .rounded: "Rounded"
        case .roundedBox: "Rounded Box"
        case .monospaced: "Monospaced"
        case .monospacedBox: "Monospaced Box"
        }
    }
    var hasBox: Bool { self == .box || self == .roundedBox || self == .monospacedBox }
}

public enum PixelateStyle: String, Codable, CaseIterable, Sendable {
    case pixelate, blur, secureBlur, blackOut
    public var title: String {
        switch self {
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        case .secureBlur: "Secure Blur"
        case .blackOut: "Black Out"
        }
    }
}

public enum SpotlightShape: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse
    public var title: String { self == .rectangle ? "Rectangle" : "Ellipse" }
}

public enum CounterStyle: String, Codable, CaseIterable, Sendable {
    case numbers, letters, roman
    public var title: String {
        switch self {
        case .numbers: "Numbers (1, 2, 3)"
        case .letters: "Letters (A, B, C)"
        case .roman: "Roman (I, II, III)"
        }
    }

    /// Label for the n-th counter (n ≥ 1). Letters continue AA, AB… after Z.
    public func label(_ n: Int) -> String {
        let n = max(1, n)
        switch self {
        case .numbers: return String(n)
        case .letters:
            var v = n, s = ""
            while v > 0 { v -= 1; s = String(UnicodeScalar(65 + v % 26)!) + s; v /= 26 }
            return s
        case .roman:
            guard n < 4000 else { return String(n) }
            let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                          (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var v = n, s = ""
            for (value, sym) in table { while v >= value { s += sym; v -= value } }
            return s
        }
    }
}

public enum HighlightShape: String, Codable, CaseIterable, Sendable {
    case freehand, rectangle
    public var title: String { self == .freehand ? "Freehand" : "Rectangle" }
}

// MARK: - Annotation

/// One annotation object. A flat value type so the whole document is a value (cheap undo snapshots,
/// trivial JSON encoding). Coordinates are document points (image pixels ÷ scale), y-down, origin at the
/// base image's top-left; objects may lie outside the image.
public struct Annotation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var kind: AnnotationKind
    /// Rect kinds: first corner. Lines/arrows: tail. Text: top-left. Counter: centre.
    public var start: CGPoint
    /// Rect kinds: opposite corner. Lines/arrows: head. Unused by text/counter/pen.
    public var end: CGPoint
    /// Curved arrow control point (absolute).
    public var control: CGPoint?
    /// Pen / freehand highlighter samples.
    public var points: [CGPoint] = []
    public var color: RGBAColor
    public var lineWidth: CGFloat
    public var shadow: Bool

    public var arrowStyle: ArrowStyle = .standard
    /// The head is drawn at `start` (CleanShot "Inverse arrow direction").
    public var inverseArrow: Bool = false

    public var text: String = ""
    /// Text: font size. Counter: circle diameter.
    public var fontSize: CGFloat = 24
    public var textStyle: TextStyle = .standard
    /// Wrap width for text; nil = single line / natural width.
    public var textWidth: CGFloat?

    public var pixelateStyle: PixelateStyle = .pixelate
    /// 0…1
    public var intensity: Double = 0.5

    public var spotlightShape: SpotlightShape = .rectangle

    public var number: Int = 1
    public var counterStyle: CounterStyle = .numbers

    public var highlightShape: HighlightShape = .freehand
    /// Highlighter opacity / image object opacity.
    public var opacity: Double = 1
    /// Freehand pen smoothing (captured from Settings at creation).
    public var smooth: Bool = true

    /// PNG data of an image object.
    public var imagePNG: Data?

    public init(kind: AnnotationKind, start: CGPoint, end: CGPoint, color: RGBAColor, lineWidth: CGFloat, shadow: Bool) {
        self.kind = kind; self.start = start; self.end = end; self.color = color; self.lineWidth = lineWidth; self.shadow = shadow
    }

    // MARK: Geometry

    /// Geometric frame (no stroke outset). Text uses `TextLayout` to measure.
    public var frame: CGRect {
        switch kind {
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .spotlight, .image:
            return Geo.rect(start, end)
        case .highlighter where highlightShape == .rectangle:
            return Geo.rect(start, end)
        case .line, .arrow:
            var r = Geo.rect(start, end)
            if let c = control, arrowStyle == .curved { r = r.union(Geo.quadBounds(start, c, end)) }
            return r
        case .pen, .highlighter:
            return Geo.bounds(of: points)
        case .text:
            return CGRect(origin: start, size: TextLayout.size(of: self))
        case .counter:
            return CGRect(x: start.x - fontSize / 2, y: start.y - fontSize / 2, width: fontSize, height: fontSize)
        }
    }

    /// Effective stroke width for freehand highlighters (wider than the configured thickness).
    var highlighterWidth: CGFloat { max(10, lineWidth * 3.5) }

    /// Area the object may paint (stroke, arrowheads, shadow).
    public var visualBounds: CGRect {
        var outset: CGFloat
        switch kind {
        case .rectangle, .ellipse, .line, .pen: outset = lineWidth / 2 + 1
        case .arrow: outset = ArrowGenerator.headLength(for: lineWidth) + lineWidth
        case .highlighter: outset = highlightShape == .freehand ? highlighterWidth / 2 + 1 : 1
        default: outset = 1
        }
        if shadow { outset += 8 }
        return frame.insetBy(dx: -outset, dy: -outset)
    }

    public func moved(by d: CGVector) -> Annotation {
        var a = self
        a.start = Geo.add(a.start, d); a.end = Geo.add(a.end, d)
        if let c = a.control { a.control = Geo.add(c, d) }
        if !a.points.isEmpty { a.points = a.points.map { Geo.add($0, d) } }
        return a
    }

    /// Maps the object from one rect onto another (scaling shapes, freehand points, image objects).
    public func mapped(from old: CGRect, to new: CGRect) -> Annotation {
        func m(_ p: CGPoint) -> CGPoint {
            let sx = old.width == 0 ? 1 : new.width / old.width, sy = old.height == 0 ? 1 : new.height / old.height
            return CGPoint(x: new.minX + (p.x - old.minX) * sx, y: new.minY + (p.y - old.minY) * sy)
        }
        var a = self
        a.start = m(start); a.end = m(end)
        if let c = control { a.control = m(c) }
        a.points = points.map(m)
        return a
    }

    /// Uniform scale about the document origin (image resize).
    public func scaled(by f: CGFloat) -> Annotation {
        var a = mapped(from: CGRect(x: 0, y: 0, width: 1, height: 1), to: CGRect(x: 0, y: 0, width: f, height: f))
        if kind == .text { a.fontSize *= f; a.textWidth = textWidth.map { $0 * f } }
        if kind == .counter { a.fontSize *= f }
        a.lineWidth *= f
        return a
    }

    /// Whether `p` touches the object. `tolerance` is in document points.
    public func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let tol = tolerance
        switch kind {
        case .rectangle:
            return Geo.distanceToRectBorder(p, frame) <= tol + lineWidth / 2
        case .ellipse:
            return Geo.distanceToEllipse(p, frame) <= tol + lineWidth / 2
        case .filledRectangle, .pixelate, .spotlight, .image, .text, .counter:
            return frame.insetBy(dx: -tol, dy: -tol).contains(p)
        case .line:
            return Geo.distance(p, segment: start, end) <= tol + lineWidth / 2
        case .arrow:
            if arrowStyle == .curved, let c = control {
                return Geo.distance(p, polyline: Geo.sampleQuad(start, c, end, steps: 32)) <= tol + lineWidth / 2 + 2
            }
            return Geo.distance(p, segment: start, end) <= tol + max(lineWidth / 2, 3)
        case .pen:
            return Geo.distance(p, polyline: points) <= tol + lineWidth / 2
        case .highlighter:
            if highlightShape == .rectangle { return frame.insetBy(dx: -tol, dy: -tol).contains(p) }
            return Geo.distance(p, polyline: points) <= tol + highlighterWidth / 2
        }
    }

    /// Whether the object intersects a marquee rect.
    public func intersects(_ r: CGRect) -> Bool {
        switch kind {
        case .pen:
            return points.contains { r.contains($0) } || r.contains(frame)
        case .highlighter where highlightShape == .freehand:
            return points.contains { r.contains($0) } || r.contains(frame)
        case .line, .arrow:
            return Geo.segmentIntersectsRect(start, end, r)
        default:
            return r.intersects(frame)
        }
    }

    // MARK: Handles

    public enum Handle: Hashable, Sendable {
        case corner(Geo.RectHandle), start, end, control, textLeft, textRight
    }

    /// Handles shown when the object is the only selection.
    public var handles: [(Handle, CGPoint)] {
        switch kind {
        case .line:
            return [(.start, start), (.end, end)]
        case .arrow:
            var h: [(Handle, CGPoint)] = [(.start, start), (.end, end)]
            if arrowStyle == .curved { h.append((.control, control ?? Geo.mid(start, end))) }
            return h
        case .text:
            let f = frame
            return [(.textLeft, CGPoint(x: f.minX, y: f.midY)), (.textRight, CGPoint(x: f.maxX, y: f.midY))]
        case .counter:
            return []
        case .pen:
            return cornerHandles
        case .highlighter where highlightShape == .freehand:
            return cornerHandles
        default:
            let f = frame
            return Geo.RectHandle.allCases.map { (.corner($0), $0.point(in: f)) }
        }
    }

    private var cornerHandles: [(Handle, CGPoint)] {
        let f = frame
        return [Geo.RectHandle.topLeft, .topRight, .bottomLeft, .bottomRight].map { (.corner($0), $0.point(in: f)) }
    }

    /// Returns the object after dragging `handle` to `p`. `original` is the object at drag start.
    public static func dragging(_ original: Annotation, handle: Handle, to p: CGPoint, shift: Bool, option: Bool) -> Annotation {
        var a = original
        switch handle {
        case .start:
            a.start = shift ? Geo.constrainAngle(p, from: original.end) : p
            if a.kind == .arrow, a.arrowStyle == .curved, original.control == nil { a.control = Geo.mid(original.start, original.end) }
        case .end:
            a.end = shift ? Geo.constrainAngle(p, from: original.start) : p
        case .control:
            a.control = p
        case .textLeft, .textRight:
            let f = original.frame
            let minW = max(original.fontSize, 20)
            if handle == .textRight {
                a.textWidth = max(minW, p.x - f.minX)
            } else {
                let w = max(minW, f.maxX - p.x)
                a.start.x = f.maxX - w
                a.textWidth = w
            }
        case .corner(let h):
            let old = original.frame
            // Image objects keep their aspect ratio unless ⇧ is held; everything else the other way round.
            let keepAspect = original.kind == .image ? !shift : shift
            let r = Geo.resize(old, handle: h, to: p, keepAspect: keepAspect, fromCenter: option)
            if original.kind.isRectBased || (original.kind == .highlighter && original.highlightShape == .rectangle) {
                // Preserve which corner start/end were on so flipping works naturally.
                a.start = r.origin
                a.end = CGPoint(x: r.maxX, y: r.maxY)
            } else {
                a = original.mapped(from: old, to: r)
            }
        }
        return a
    }
}

// MARK: - Counters

public extension Array where Element == Annotation {
    /// The number the next counter should show: one more than the highest existing counter, or `start`.
    func nextCounterNumber(start: Int) -> Int {
        let numbers = filter { $0.kind == .counter }.map(\.number)
        return (numbers.max().map { $0 + 1 }) ?? start
    }
}
