import AppKit
import CoreImage
import ImageIO
import ShotcraftCore

/// Full-image CoreImage results for the pixelate tool, cached per base image + style + intensity
/// (CleanShot: `ANPixelateInstance(ciImage, pixelatedImage, retinaFactor, style)`).
final class EffectCache {
    private static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                       .cacheIntermediates: false])
    private var source: CGImage?
    private var cache: [String: CGImage] = [:]

    func processed(_ image: CGImage, style: PixelateStyle, intensity: Double, scale: CGFloat) -> CGImage? {
        if source !== image { cache.removeAll(); source = image }
        let level = Int((max(0, min(1, intensity)) * 20).rounded())
        let key = "\(style.rawValue)-\(level)"
        if let hit = cache[key] { return hit }
        guard let out = Self.apply(image, style: style, level: Double(level) / 20, scale: scale) else { return nil }
        if cache.count > 6 { cache.removeAll() }
        cache[key] = out
        return out
    }

    /// Pixel block size in *pixels* for a given intensity.
    static func blockSize(level: Double, scale: CGFloat) -> CGFloat { (5 + CGFloat(level) * 30) * max(scale, 1) }

    static func apply(_ image: CGImage, style: PixelateStyle, level: Double, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        var out: CIImage?
        switch style {
        case .pixelate:
            out = pixellate(input, block: blockSize(level: level, scale: scale))
        case .blur:
            let radius = (3 + level * 27) * Double(max(scale, 1))
            out = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        case .secureBlur:
            // Pixelate first so no recoverable detail survives, then blur the blocks smooth.
            let block = blockSize(level: max(level, 0.3), scale: scale) * 0.6
            out = pixellate(input, block: block)?.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(block) * 0.9).cropped(to: extent)
        case .blackOut:
            return nil
        }
        guard let o = out else { return nil }
        return render(o, extent: extent)
    }

    static func render(_ image: CIImage, extent: CGRect) -> CGImage? {
        ciContext.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func pixellate(_ input: CIImage, block: CGFloat) -> CIImage? {
        guard let f = CIFilter(name: "CIPixellate") else { return nil }
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(max(2, block), forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: input.extent.minX, y: input.extent.maxY), forKey: kCIInputCenterKey)
        return f.outputImage?.cropped(to: input.extent)
    }
}

/// Decoded image objects keyed by annotation id (image data never changes for a given id).
final class ImageObjectCache {
    private var cache: [UUID: (Int, CGImage)] = [:]

    func image(for a: Annotation) -> CGImage? {
        guard let data = a.imagePNG else { return nil }
        if let (count, img) = cache[a.id], count == data.count { return img }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[a.id] = (data.count, img)
        return img
    }
}

/// Wallpaper / custom background images, loaded once per path and downscaled for speed.
final class WallpaperCache {
    private var cache: [String: CGImage] = [:]

    func image(path: String, maxPixel: Int = 3200) -> CGImage? {
        if let hit = cache[path] { return hit }
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        cache[path] = img
        return img
    }

    func image(data: Data) -> CGImage? {
        // Data's own hash only covers a short prefix (identical across JPEG headers), so sample the tail too.
        var h = Hasher()
        h.combine(data.count)
        h.combine(data.prefix(256))
        h.combine(data.suffix(256))
        if data.count > 1024 { h.combine(data[data.startIndex + data.count / 2 ..< data.startIndex + data.count / 2 + 256]) }
        let key = "data-\(h.finalize())"
        if let hit = cache[key] { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache[key] = img
        return img
    }

    private var blurCache: (source: CGImage, result: CGImage)?

    /// A heavily blurred, downscaled copy of `image` (the "Blurred wallpaper" background).
    func blurred(_ image: CGImage) -> CGImage? {
        if let c = blurCache, c.source === image { return c.result }
        let longest = CGFloat(max(image.width, image.height))
        let small = longest > 640 ? ImageTools.resized(image, factor: 640 / longest) : image
        let input = CIImage(cgImage: small)
        let sigma = Double(max(small.width, small.height)) * 0.04
        let out = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let result = EffectCache.render(out, extent: input.extent) else { return nil }
        blurCache = (image, result)
        return result
    }

    /// JPEG thumbnail of a wallpaper for embedding in documents.
    static func embeddable(path: String) -> Data? {
        guard let img = WallpaperCache().image(path: path, maxPixel: 2400) else { return nil }
        return ImageTools.encode(img, format: .jpeg, quality: 0.85)
    }

    /// The image a background fill needs embedded so a project renders the same on another Mac
    /// (custom images, the desktop wallpaper of `screen`, the blurred wallpaper). nil for generated fills.
    @MainActor
    static func embeddedData(for fill: BackgroundFill, screen: NSScreen?) -> Data? {
        switch fill {
        case .image(let path): return embeddable(path: path)
        case .desktop, .blurred(.wallpaper):
            guard let s = screen ?? NSScreen.main, let u = NSWorkspace.shared.desktopImageURL(for: s) else { return nil }
            return embeddable(path: u.path)
        default: return nil
        }
    }
}
