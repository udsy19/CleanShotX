import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import SuperScreenshotCore

/// Turns a capture file into an `UploadItem`, down-scaling images wider than the maximum upload width
/// into a temporary copy ("Set maximum resolution to reduce file size and upload time.").
public enum UploadPreparation {
    struct Prepared: Sendable {
        var item: UploadItem
        /// Temp directory holding a processed copy; delete after the upload.
        var temporaryDirectory: URL?
    }

    /// Pixel size after limiting the width to `maxWidth` (aspect preserved), or nil when no scaling is needed.
    public static func scaledSize(width: Int, height: Int, maxWidth: Int) -> (width: Int, height: Int)? {
        guard maxWidth > 0, width > maxWidth, width > 0 else { return nil }
        let h = max(1, Int((Double(height) * Double(maxWidth) / Double(width)).rounded()))
        return (maxWidth, h)
    }

    public static func contentType(forFileName name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func imageFormat(forExtension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "heic": .heic
        case "tif", "tiff": .tiff
        default: nil
        }
    }

    static func prepare(fileURL: URL, isImage: Bool, maxWidth: Int) throws -> Prepared {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            throw UploadError.failed("The file “\(fileURL.lastPathComponent)” no longer exists.")
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            throw UploadError.failed("Projects can't be uploaded directly. Export the video first, then upload it.")
        }
        let name = fileURL.lastPathComponent
        if isImage, let format = imageFormat(forExtension: fileURL.pathExtension),
           let image = ImageTools.load(fileURL),
           let target = scaledSize(width: image.width, height: image.height, maxWidth: maxWidth) {
            let scaled = ImageTools.resized(image, factor: CGFloat(target.width) / CGFloat(image.width))
            let dir = AppPaths.temporary.appendingPathComponent("Uploads/\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent(name)
            do {
                try ImageTools.write(scaled, to: out, format: format)
            } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
            return Prepared(item: UploadItem(fileURL: out, fileName: name, contentType: contentType(forFileName: name),
                                             size: fileSize(out)), temporaryDirectory: dir)
        }
        return Prepared(item: UploadItem(fileURL: fileURL, fileName: name, contentType: contentType(forFileName: name),
                                         size: fileSize(fileURL)), temporaryDirectory: nil)
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
