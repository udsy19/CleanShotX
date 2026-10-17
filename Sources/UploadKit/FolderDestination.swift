import Foundation
import SuperScreenshotCore

/// "Upload" by copying into a (typically synced) folder; the link is built from a URL prefix.
struct FolderConfiguration: Sendable {
    var folder: URL
    var urlPrefix: String

    static func current() throws -> FolderConfiguration {
        let path = Defaults[.uploadFolderPath].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw UploadError.failed("Choose an upload folder in Settings → Upload.") }
        return FolderConfiguration(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
                                   urlPrefix: Defaults[.uploadFolderURLPrefix].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Prefix + percent-encoded file name, or a file URL when no prefix is set.
    func link(for destination: URL) -> URL? {
        UploadNaming.folderLink(prefix: urlPrefix, fileURL: destination)
    }

    /// Unused destination for `fileName` inside the folder.
    func reserveDestination(fileName: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return AppPaths.uniqueURL(folder.appendingPathComponent(fileName))
    }

    /// Chunked copy with progress into a hidden partial file, then an atomic move so sync clients
    /// never pick up a half-written file.
    func copy(_ source: URL, to destination: URL, progress: @Sendable (Int64) -> Void) throws {
        let fm = FileManager.default
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw UploadError.failed("Super Screenshot can't write to “\(folder.path)”. Check the folder's permissions.")
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            var sent: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                if Task.isCancelled { throw CancellationError() }
                try output.write(contentsOf: chunk)
                sent += Int64(chunk.count)
                progress(sent)
            }
            try output.synchronize()
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }
}
