import Foundation
import SuperScreenshotCore

/// Crash recovery for Annotate: while an editor has unsaved edits, a full `.superscreenshot` copy of its
/// document lives in `AppPaths.recovery` under the editor's id. A clean close removes it; whatever is
/// still there at the next launch is offered back to the user (`AnnotateService.recoverUnsavedDocuments`).
public enum AnnotateRecovery {
    /// Where the editor with `id` keeps its copy.
    public static func fileURL(for id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension(SuperScreenshotDocument.fileExtension)
    }

    /// Recovery copies in `folder` (current extension only, oldest first).
    public static func pendingDocuments(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return urls.filter { $0.pathExtension.lowercased() == SuperScreenshotDocument.fileExtension }
            .sorted { date($0) < date($1) }
    }

    /// Decodes every recovery copy in `folder`. A copy that can't be read (a crash mid-write, a damaged
    /// disk) is logged and deleted so it is never offered again.
    public static func load(in folder: URL) -> [(url: URL, document: SuperScreenshotDocument.Loaded)] {
        pendingDocuments(in: folder).compactMap { url in
            do {
                return (url, try SuperScreenshotDocument.decode(Data(contentsOf: url)))
            } catch {
                Log.annotate.error("Dropping unreadable recovery file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
    }
}

/// One editor's recovery copy. `schedule` debounces on the main queue; the encode + atomic write run on a
/// serial background queue from an immutable snapshot (CanvasState is a value, its CGImage is shared), so an
/// 8K base image never blocks the UI, and `discard` is queued behind any write in flight so a late autosave
/// can never resurrect the file after the editor closed (same pattern as StudioKit's EditorModel).
public final class RecoveryWriter {
    public let url: URL
    private var pending: DispatchWorkItem?
    /// False until the first `schedule`: a clean document has nothing on disk to remove.
    private var mayExist = false
    private static let io = DispatchQueue(label: "superscreenshot.annotate.recovery-io", qos: .utility)

    public init(url: URL) { self.url = url }

    /// Writes `state` after `delay` seconds; a newer call replaces an unfired one. Main thread only.
    public func schedule(_ state: CanvasState, sourceURL: URL?, createdAt: Date, delay: TimeInterval = 1) {
        cancelPending()
        mayExist = true
        let url = self.url
        let item = DispatchWorkItem {
            Self.io.async {
                do {
                    let data = try SuperScreenshotDocument.encode(state, sourceURL: sourceURL, createdAt: createdAt, includePreview: false)
                    try data.write(to: url, options: .atomic)
                } catch {
                    Log.annotate.error("Recovery save failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Starts a pending write now instead of waiting for the debounce (window deactivation).
    public func flush() {
        guard let item = pending else { return }
        pending = nil
        item.perform()
        item.cancel()   // the asyncAfter copy must not run it a second time
    }

    /// Drops a pending write and removes the file (after any write already running).
    public func discard() {
        cancelPending()
        guard mayExist else { return }
        mayExist = false
        let url = self.url
        Self.io.async { try? FileManager.default.removeItem(at: url) }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    /// Blocks until every queued write/remove has finished (self-tests).
    public static func drain() { io.sync {} }
}
