import AppKit
import CoreText
import ImageIO

/// A rendered cursor bitmap and its hot spot (pixels, top-left origin).
struct CursorBitmap: @unchecked Sendable {
    let image: CGImage
    let hotSpot: CGPoint
}

/// Thread-safe vector artwork (cursor shapes, keystroke labels, background images) with small caches.
/// Everything is drawn with CoreGraphics/CoreText so it can run on the compositor's render queue.
final class Artwork: @unchecked Sendable {
    static let shared = Artwork()
    private let lock = NSLock()
    private var cursorCache: [String: CursorBitmap] = [:]
    private var labelCache: [String: CGImage] = [:]
    private var labelOrder: [String] = []
    private var imageCache: [String: CGImage] = [:]
    /// System pointing-hand cursor, captured on the main thread (NSCursor isn't safe off-main).
    private var handImage: CGImage?
    private var handHotSpot = CGPoint(x: 0.3, y: 0.05)

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Call once on the main thread before rendering.
    @MainActor func prepare() {
        lock.lock(); defer { lock.unlock() }
        guard handImage == nil else { return }
        let cursor = NSCursor.pointingHand
        let img = cursor.image
        var r = CGRect(origin: .zero, size: CGSize(width: img.size.width * 4, height: img.size.height * 4))
        if let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) {
            handImage = cg
            handHotSpot = CGPoint(x: cursor.hotSpot.x / max(img.size.width, 1), y: cursor.hotSpot.y / max(img.size.height, 1))
        }
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: max(w, 1), height: max(h, 1), bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: Cursor

    /// Cursor bitmap about `height` pixels tall (quantized for caching).
    func cursor(kind: CursorKind, style: CursorStyle, height: CGFloat) -> CursorBitmap? {
        let h = max(8, (height / 4).rounded() * 4)
        let key = "\(kind.rawValue)-\(style.rawValue)-\(Int(h))"
        lock.lock()
        if let c = cursorCache[key] { lock.unlock(); return c }
        let hand = handImage, handHot = handHotSpot
        lock.unlock()
        let made: CursorBitmap?
        switch (style, kind) {
        case (.touch, _): made = Self.touch(height: h)
        case (_, .iBeam): made = Self.iBeam(height: h, inverted: style == .inverted)
        case (_, .pointingHand):
            if let hand { made = Self.bitmap(hand, height: h, hot: handHot) } else { made = Self.arrow(height: h, inverted: style == .inverted) }
        default: made = Self.arrow(height: h, inverted: style == .inverted)
        }
        if let made { lock.lock(); cursorCache[key] = made; lock.unlock() }
        return made
    }

    /// Classic arrow pointer: 12×19 design units, filled with a contrasting outline and a soft shadow.
    private static func arrow(height h: CGFloat, inverted: Bool) -> CursorBitmap? {
        let u = h / 22
        let pad = 3 * u
        let w = Int((13 * u + pad * 2).rounded(.up)), H = Int((19.5 * u + pad * 2).rounded(.up))
        guard let ctx = context(w, H) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)   // top-left drawing space
        ctx.translateBy(x: pad, y: pad)
        let pts: [CGPoint] = [(0, 0), (0, 16), (3.9, 12.4), (6.6, 18.4), (9.1, 17.3), (6.5, 11.4), (11.6, 11.4)].map { CGPoint(x: $0.0 * u, y: $0.1 * u) }
        let path = CGMutablePath()
        path.addLines(between: pts); path.closeSubpath()
        let fill = inverted ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
        let line = inverted ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * u), blur: 2.2 * u, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(path); ctx.setLineJoin(.round); ctx.setLineWidth(2.2 * u); ctx.setStrokeColor(line); ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
        guard let img = ctx.makeImage() else { return nil }
        return CursorBitmap(image: img, hotSpot: CGPoint(x: pad, y: pad))
    }

    private static func iBeam(height h: CGFloat, inverted: Bool) -> CursorBitmap? {
        let u = h / 22
        let pad = 3 * u
        let w = Int((8 * u + pad * 2).rounded(.up)), H = Int((18 * u + pad * 2).rounded(.up))
        guard let ctx = context(w, H) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: pad, y: pad)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0)); path.addQuadCurve(to: CGPoint(x: 4 * u, y: 1.5 * u), control: CGPoint(x: 3 * u, y: 0))
        path.addQuadCurve(to: CGPoint(x: 8 * u, y: 0), control: CGPoint(x: 5 * u, y: 0))
        path.move(to: CGPoint(x: 4 * u, y: 1.5 * u)); path.addLine(to: CGPoint(x: 4 * u, y: 16.5 * u))
        path.move(to: CGPoint(x: 0, y: 18 * u)); path.addQuadCurve(to: CGPoint(x: 4 * u, y: 16.5 * u), control: CGPoint(x: 3 * u, y: 18 * u))
        path.addQuadCurve(to: CGPoint(x: 8 * u, y: 18 * u), control: CGPoint(x: 5 * u, y: 18 * u))
        let fg = inverted ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
        let bg = inverted ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        ctx.setLineCap(.round)
        ctx.addPath(path); ctx.setLineWidth(3.2 * u); ctx.setStrokeColor(bg); ctx.strokePath()
        ctx.addPath(path); ctx.setLineWidth(1.4 * u); ctx.setStrokeColor(fg); ctx.strokePath()
        guard let img = ctx.makeImage() else { return nil }
        return CursorBitmap(image: img, hotSpot: CGPoint(x: pad + 4 * u, y: pad + 9 * u))
    }

    private static func touch(height h: CGFloat) -> CursorBitmap? {
        let d = h * 0.9
        let pad = h * 0.1
        let s = Int((d + pad * 2).rounded(.up))
        guard let ctx = context(s, s) else { return nil }
        let r = CGRect(x: pad, y: pad, width: d, height: d)
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 0.45)); ctx.fillEllipse(in: r)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(max(1.5, h * 0.07))
        ctx.strokeEllipse(in: r.insetBy(dx: h * 0.035, dy: h * 0.035))
        guard let img = ctx.makeImage() else { return nil }
        return CursorBitmap(image: img, hotSpot: CGPoint(x: CGFloat(s) / 2, y: CGFloat(s) / 2))
    }

    private static func bitmap(_ src: CGImage, height h: CGFloat, hot: CGPoint) -> CursorBitmap? {
        let f = h / CGFloat(src.height) * 1.1
        let w = Int((CGFloat(src.width) * f).rounded()), H = Int((CGFloat(src.height) * f).rounded())
        guard let ctx = context(w, H) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: H))
        guard let img = ctx.makeImage() else { return nil }
        return CursorBitmap(image: img, hotSpot: CGPoint(x: hot.x * CGFloat(w), y: hot.y * CGFloat(H)))
    }

    // MARK: Keystroke labels

    /// A dark pill containing `text`, `fontSize` pixels.
    func label(_ text: String, fontSize: CGFloat) -> CGImage? {
        let size = max(8, fontSize.rounded())
        let key = "\(Int(size))|\(text)"
        lock.lock()
        if let img = labelCache[key] { lock.unlock(); return img }
        lock.unlock()
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) ?? font
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): bold,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padX = size * 0.75, padY = size * 0.45
        let w = Int((width + padX * 2).rounded(.up)), h = Int((ascent + descent + padY * 2).rounded(.up))
        guard let ctx = Self.context(w, h) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let radius = min(CGFloat(h) / 2, size * 0.6)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.82)); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1); ctx.strokePath()
        ctx.textPosition = CGPoint(x: padX, y: padY + descent)
        CTLineDraw(line, ctx)
        guard let img = ctx.makeImage() else { return nil }
        lock.lock()
        labelCache[key] = img
        labelOrder.append(key)
        if labelOrder.count > 96 { labelCache[labelOrder.removeFirst()] = nil }
        lock.unlock()
        return img
    }

    // MARK: Background images

    /// Decoded image (downsampled to at most `maxPixel`) for a background file.
    func image(at url: URL, maxPixel: Int = 3840) -> CGImage? {
        let key = url.path
        lock.lock()
        if let img = imageCache[key] { lock.unlock(); return img }
        lock.unlock()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        lock.lock()
        if imageCache.count > 8 { imageCache.removeAll() }
        imageCache[key] = img
        lock.unlock()
        return img
    }
}
