import AppKit
import AVFoundation

/// Reads a displayable image from Shotcraft documents without linking the app's modules:
/// `.shotcraft` → the embedded flattened `preview` PNG (falls back to the base image);
/// `.shotcraftvideo` package → a poster frame of `screen.mov`.
enum ShotcraftPreview {
    static func image(for url: URL, maxPixel: CGFloat) -> CGImage? {
        if url.pathExtension.lowercased() == "shotcraftvideo" { return posterFrame(url.appendingPathComponent("screen.mov"), maxPixel: maxPixel) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        struct Blob: Decodable { var png: Data }
        struct File: Decodable { var format: String; var image: Blob; var preview: Data? }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == "com.udsy.shotcraft.document" else { return nil }
        return decode(file.preview ?? file.image.png, maxPixel: maxPixel)
    }

    private static func decode(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func posterFrame(_ movie: URL, maxPixel: CGFloat) -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let sema = DispatchSemaphore(value: 0)
        var result: CGImage?
        gen.generateCGImageAsynchronously(for: CMTime(seconds: 0.5, preferredTimescale: 600)) { img, _, _ in
            result = img; sema.signal()
        }
        _ = sema.wait(timeout: .now() + 10)
        return result
    }
}
