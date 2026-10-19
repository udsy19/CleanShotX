import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Why an image couldn't be produced or written.
public enum ImageError: LocalizedError, Equatable {
    /// More pixels than `ImageTools.maxPixelCount`.
    case tooLarge(width: Int, height: Int)
    /// A bitmap of this size couldn't be allocated.
    case outOfMemory(width: Int, height: Int)
    case encodingFailed
    /// `ImageTools.write` refused to replace a file that appeared at the destination.
    case fileExists(URL)

    public var errorDescription: String? {
        switch self {
        case let .tooLarge(w, h):
            "This capture is too large to process (\(w) × \(h) pixels). Try capturing a smaller area."
        case let .outOfMemory(w, h):
            "There isn't enough memory to process a \(w) × \(h) pixel image. Try capturing a smaller area."
        case .encodingFailed: "There was an error while compressing your image."
        case .fileExists(let url): "A file named “\(url.lastPathComponent)” already exists."
        }
    }
}

/// CGImage load/encode helpers and the screenshot post-processing chain.
public enum ImageTools {
    /// Largest bitmap the app will allocate (≈ 1.6 GB of RGBA): well above three 5K displays (≈ 44 MP) but far
    /// below sizes that would exhaust memory and take the process down.
    public static let maxPixelCount = 400_000_000

    /// Throws a clear error when a `width × height` bitmap would exceed `maxPixelCount`.
    public static func validateSize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maxPixelCount else { throw ImageError.tooLarge(width: width, height: height) }
    }

    public static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double = Defaults[.jpegQuality],
                              dpi: CGFloat = 72) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        // A corrupt preference (e.g. 12 or -1) must not make the encoder fail.
        if format == .jpeg || format == .heic { props[kCGImageDestinationLossyCompressionQuality] = min(max(quality.isFinite ? quality : 0.9, 0), 1) }
        // JPEG has no alpha: flatten onto white.
        let img = (format == .jpeg && image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst)
            ? flattened(image, background: .white) : image
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Encodes and writes atomically: the bytes go to a hidden temporary file next to `url`, which is then renamed
    /// into place, so a crash mid-write never leaves a truncated image under the final name. With `replacing`
    /// false (captures) the rename refuses to overwrite a file that appeared meanwhile and throws
    /// `ImageError.fileExists`, so two captures can never clobber each other.
    @discardableResult
    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, scale: CGFloat = 1,
                             replacing: Bool = true) throws -> URL {
        guard let data = encode(image, format: format, dpi: 72 * scale) else { throw ImageError.encodingFailed }
        try writeAtomically(data, to: url, replacing: replacing)
        return url
    }

    /// `Data.write(.atomic)` that can refuse to replace an existing file (see `write(_:to:format:scale:replacing:)`).
    public static func writeAtomically(_ data: Data, to url: URL, replacing: Bool) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        try data.write(to: temp, options: [])
        let status = url.withUnsafeFileSystemRepresentation { dst in
            temp.withUnsafeFileSystemRepresentation { src in
                replacing ? rename(src!, dst!) : renamex_np(src!, dst!, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            if code == EEXIST { throw ImageError.fileExists(url) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code)), NSFilePathErrorKey: url.path])
        }
    }

    public static func pngData(_ image: CGImage) -> Data? { encode(image, format: .png) }

    // MARK: - Processing

    /// An sRGB RGBA bitmap context, or nil when the size is absurd (`maxPixelCount`) or memory is exhausted.
    public static func context(width: Int, height: Int, colorSpace: CGColorSpace? = nil) -> CGContext? {
        guard (try? validateSize(width: width, height: height)) != nil else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Like `context(width:height:)` but explains a failure (too large vs. out of memory).
    public static func checkedContext(width: Int, height: Int) throws -> CGContext {
        try validateSize(width: width, height: height)
        guard let ctx = context(width: width, height: height) else { throw ImageError.outOfMemory(width: width, height: height) }
        return ctx
    }

    /// True when every sampled pixel is fully transparent: a screen capture never is (the desktop is opaque), so
    /// it means the system handed back nothing — typically a stale Screen Recording permission.
    public static func isFullyTransparent(_ image: CGImage, samples: Int = 24) -> Bool {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return true }
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return false }
        let n = max(1, min(samples, w, h))
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return false }
        // Nearest-neighbour shrink: one source pixel per sample, no blending that could hide alpha.
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let px = data.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 3, to: n * n * 4, by: 4) where px[i] != 0 { return false }
        return true
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
