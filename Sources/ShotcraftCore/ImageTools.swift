import AppKit
import ImageIO
import UniformTypeIdentifiers

/// CGImage load/encode helpers and the screenshot post-processing chain.
public enum ImageTools {
    public static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double = Defaults[.jpegQuality],
                              dpi: CGFloat = 72) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpeg || format == .heic { props[kCGImageDestinationLossyCompressionQuality] = quality }
        // JPEG has no alpha: flatten onto white.
        let img = (format == .jpeg && image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst)
            ? flattened(image, background: .white) : image
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    @discardableResult
    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, scale: CGFloat = 1) throws -> URL {
        guard let data = encode(image, format: format, dpi: 72 * scale) else {
            throw NSError(domain: "Shotcraft", code: 1, userInfo: [NSLocalizedDescriptionKey: "There was an error while compressing your image."])
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func pngData(_ image: CGImage) -> Data? { encode(image, format: .png) }

    // MARK: - Processing

    public static func context(width: Int, height: Int, colorSpace: CGColorSpace? = nil) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    public static func flattened(_ image: CGImage, background: RGBAColor) -> CGImage {
        guard let ctx = context(width: image.width, height: image.height) else { return image }
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    public static func resized(_ image: CGImage, factor: CGFloat) -> CGImage {
        let w = max(1, Int((CGFloat(image.width) * factor).rounded())), h = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let ctx = context(width: w, height: h, colorSpace: image.colorSpace) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    public static func convertedToSRGB(_ image: CGImage) -> CGImage {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        return image.copy(colorSpace: srgb) ?? {
            guard let ctx = context(width: image.width, height: image.height, colorSpace: srgb) else { return image }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return ctx.makeImage() ?? image
        }()
    }

    /// 1px (one *pixel*) hairline border around the image.
    public static func bordered(_ image: CGImage, color: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.25)) -> CGImage {
        guard let ctx = context(width: image.width, height: image.height, colorSpace: image.colorSpace) else { return image }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: r)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        return ctx.makeImage() ?? image
    }

    public static func cropped(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        image.cropping(to: pixelRect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
    }

    /// Applies the Screenshots preferences (retina → 1x, sRGB, border). Returns image + effective scale.
    public static func applyScreenshotPreferences(_ image: CGImage, scale: CGFloat) -> (CGImage, CGFloat) {
        var img = image, s = scale
        if Defaults[.scaleRetinaScreenshotsTo1x] && scale > 1 { img = resized(img, factor: 1 / scale); s = 1 }
        if Defaults[.convertToSRGB] { img = convertedToSRGB(img) }
        if Defaults[.addBorderToScreenshots] { img = bordered(img) }
        return (img, s)
    }

    public static func nsImage(_ cg: CGImage, scale: CGFloat = 1) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }
}

public extension NSImage {
    var cgImage: CGImage? {
        var r = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}
