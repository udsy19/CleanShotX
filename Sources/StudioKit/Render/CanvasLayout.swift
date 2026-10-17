import Foundation
import CoreGraphics

/// Where the recording sits on the output canvas. Pixel rects use Core Image's bottom-left origin.
public struct CanvasLayout: Equatable, Sendable {
    public let canvasSize: CGSize
    /// Part of the source frame that is shown (after inset), source pixels.
    public let cropRect: CGRect
    /// Where `cropRect` lands on the canvas.
    public let screenRect: CGRect
    /// Pixels per "reference pixel" (canvas short side / 1080) — scales corner radius, shadows, labels.
    public let unit: CGFloat
    public let sourceSize: CGSize

    public init(sourceSize: CGSize, style: StudioStyle, canvasSize: CGSize) {
        self.sourceSize = sourceSize
        self.canvasSize = canvasSize
        cropRect = Self.cropRect(sourceSize: sourceSize, inset: style.inset)
        unit = min(canvasSize.width, canvasSize.height) / 1080
        let pad = CGFloat(style.effectivePadding) * min(canvasSize.width, canvasSize.height)
        let avail = CGRect(origin: .zero, size: canvasSize).insetBy(dx: pad, dy: pad)
        let k = min(avail.width / max(cropRect.width, 1), avail.height / max(cropRect.height, 1))
        let w = cropRect.width * k, h = cropRect.height * k
        screenRect = CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
    }

    static func cropRect(sourceSize: CGSize, inset: Double) -> CGRect {
        let i = CGFloat(min(max(inset, 0), 0.2)) * min(sourceSize.width, sourceSize.height)
        return CGRect(origin: .zero, size: sourceSize).insetBy(dx: i, dy: i)
    }

    /// Canvas size before export scaling: the recording (after inset) extended to the aspect ratio.
    public static func baseCanvasSize(sourceSize: CGSize, style: StudioStyle) -> CGSize {
        let crop = cropRect(sourceSize: sourceSize, inset: style.inset).size
        guard let r = style.aspectRatio.value else { return even(crop) }
        if crop.width / crop.height > r { return even(CGSize(width: crop.width, height: crop.width / r)) }
        return even(CGSize(width: crop.height * r, height: crop.height))
    }

    /// Scales `base` so its short side equals `shortSide` (nil = unchanged), keeping even dimensions.
    public static func scaled(_ base: CGSize, shortSide: Double?) -> CGSize {
        guard let shortSide else { return even(base) }
        let f = shortSide / Double(min(base.width, base.height))
        return even(CGSize(width: Double(base.width) * f, height: Double(base.height) * f))
    }

    /// Fits `size` inside `maxSize` (never upscales).
    public static func fitted(_ size: CGSize, within maxSize: CGSize) -> CGSize {
        let f = min(1, min(maxSize.width / size.width, maxSize.height / size.height))
        return even(CGSize(width: size.width * f, height: size.height * f))
    }

    public static func even(_ s: CGSize) -> CGSize {
        CGSize(width: max(2, (s.width / 2).rounded() * 2), height: max(2, (s.height / 2).rounded() * 2))
    }

    /// Source-pixel → canvas-pixel transform.
    public var placement: CGAffineTransform {
        let k = screenRect.width / max(cropRect.width, 1)
        return CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: screenRect.minX, y: screenRect.minY))
    }

    /// Screen-pixels per canvas-pixel ratio (how big one source pixel is on the canvas).
    public var screenScale: CGFloat { screenRect.width / max(cropRect.width, 1) }

    /// Normalized recording point (top-left origin) → canvas pixel (bottom-left origin).
    public func canvasPoint(_ p: NPoint) -> CGPoint {
        CGPoint(x: p.x * sourceSize.width, y: (1 - p.y) * sourceSize.height).applying(placement)
    }

    /// Normalized recording point → normalized canvas point (both top-left origin).
    public func canvasNormalized(_ p: NPoint) -> NPoint {
        let c = canvasPoint(p)
        return NPoint(x: Double(c.x / canvasSize.width), y: Double(1 - c.y / canvasSize.height))
    }

    /// Canvas-pixel → output-pixel transform for a viewport.
    public func zoomTransform(_ v: Viewport) -> CGAffineTransform {
        let s = CGFloat(v.scale)
        let ox = v.rect.minX * canvasSize.width
        let oy = (1 - v.rect.maxY) * canvasSize.height
        return CGAffineTransform(translationX: -ox, y: -oy).concatenating(CGAffineTransform(scaleX: s, y: s))
    }
}
