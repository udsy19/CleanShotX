import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based Quick Look preview (space bar in Finder) for Super Screenshot documents and Studio projects.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        guard let image = SuperScreenshotPreview.image(for: request.fileURL, maxPixel: 4096) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = CGSize(width: image.width, height: image.height)
        return QLPreviewReply(dataOfContentType: .png, contentSize: size) { _ in
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            return png
        }
    }
}
