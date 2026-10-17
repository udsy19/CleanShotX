import AppKit
import QuickLookThumbnailing

/// Finder icons/thumbnails for Shotcraft documents and Studio projects.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let maxPixel = max(request.maximumSize.width, request.maximumSize.height) * request.scale
        guard let image = ShotcraftPreview.image(for: request.fileURL, maxPixel: maxPixel) else {
            handler(nil, CocoaError(.fileReadCorruptFile)); return
        }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let box = request.maximumSize
        let size = aspect >= box.width / box.height ? CGSize(width: box.width, height: box.width / aspect)
                                                    : CGSize(width: box.height * aspect, height: box.height)
        handler(QLThumbnailReply(contextSize: size) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            return true
        }, nil)
    }
}
