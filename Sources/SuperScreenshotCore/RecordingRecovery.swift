import AVFoundation
import AppKit

/// Crash safety for recordings that are being written.
///
/// Recorders write their media into `AppPaths.inProgress` next to a small manifest, with movie fragments enabled
/// on the writer, so a crash, force quit, power loss or a kill by the system (e.g. a permission revoked mid-recording)
/// leaves a file that is readable up to the last fragment. `recoverAll` runs at launch and turns whatever is left
/// there into an ordinary recording.
public enum RecordingRecovery {
    /// Fragment interval for every recording writer: at most this much is lost when the process dies.
    public static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    public struct Manifest: Codable, Equatable, Sendable {
        public var id: UUID
        /// What the recording was going to become (`.gif` is salvaged as a video).
        public var kind: MediaKind
        public var mode: CaptureMode
        /// File stem the recording would have been saved under.
        public var name: String
        /// Media file, relative to the in-progress folder (may live inside a package folder).
        public var file: String
        public var startedAt: Date
        /// The process that was writing it; a live one is still recording and is left alone.
        public var pid: Int32
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var scale: Double

        public init(kind: MediaKind, mode: CaptureMode, name: String, file: String, pixelSize: CGSize, scale: CGFloat,
                    id: UUID = UUID(), startedAt: Date = Date(), pid: Int32 = getpid()) {
            self.id = id; self.kind = kind; self.mode = mode; self.name = name; self.file = file
            self.startedAt = startedAt; self.pid = pid
            pixelWidth = Int(pixelSize.width); pixelHeight = Int(pixelSize.height); self.scale = Double(scale)
        }

        public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    }

    /// Handed to the recorder: where to write and what to clean up.
    public struct Token: Sendable {
        public let manifest: Manifest
        let manifestURL: URL
        /// The file the writer must write to.
        public let mediaURL: URL
    }

    /// `~/Library/Application Support/SuperScreenshot/InProgress`
    public static var directory: URL { AppPaths.ensure(AppPaths.support.appendingPathComponent("InProgress", isDirectory: true)) }

    // MARK: Bookkeeping (recorders)

    /// Registers a recording that is about to start. The recorder writes to `token.mediaURL`.
    public static func begin(_ manifest: Manifest, in directory: URL = directory) throws -> Token {
        let media = directory.appendingPathComponent(manifest.file)
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifestURL = Self.manifestURL(for: manifest.id, in: directory)
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        return Token(manifest: manifest, manifestURL: manifestURL, mediaURL: media)
    }

    /// The media was moved to its final place: only the manifest is left to remove.
    public static func finish(_ token: Token) {
        try? FileManager.default.removeItem(at: token.manifestURL)
    }

    /// Nothing worth keeping (deleted, restarted, delivered elsewhere): removes the media and its manifest.
    public static func abandon(_ token: Token) {
        try? FileManager.default.removeItem(at: packageOrFile(for: token.manifest, in: token.manifestURL.deletingLastPathComponent()))
        try? FileManager.default.removeItem(at: token.manifestURL)
    }

    /// Moves the finished media to `destination` (made unique) and clears the manifest. If the move fails the
    /// media stays where it is, still referenced by the returned URL, so nothing is lost.
    public static func complete(_ token: Token, movingTo destination: URL) -> URL {
        let dest = AppPaths.uniqueURL(destination)
        do {
            try FileManager.default.moveItem(at: token.mediaURL, to: dest)
            finish(token)
            return dest
        } catch {
            Log.recording.error("Couldn't move the finished recording: \(error.localizedDescription, privacy: .public)")
            finish(token)
            return token.mediaURL
        }
    }

    private static func manifestURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    /// The top-level item the manifest's media belongs to (the package folder, or the file itself).
    private static func packageOrFile(for manifest: Manifest, in directory: URL) -> URL {
        let first = manifest.file.split(separator: "/").first.map(String.init) ?? manifest.file
        return directory.appendingPathComponent(first)
    }

    // MARK: Recovery (launch)

    public struct Pending: Equatable, Sendable {
        public var manifest: Manifest
        public var mediaURL: URL
    }

    /// Recordings left behind by a process that is gone. Manifests that are corrupt or whose media is missing are
    /// removed; anything else in the folder that no manifest references and is older than a day is swept.
    public static func pending(in directory: URL = directory, isAlive: (Int32) -> Bool = processIsAlive) -> [Pending] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var result: [Pending] = []
        var referenced: Set<String> = []
        for url in items where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
                Log.recording.error("Removing unreadable recording manifest \(url.lastPathComponent, privacy: .public)")
                try? fm.removeItem(at: url)
                continue
            }
            referenced.insert(url.lastPathComponent)
            referenced.insert(packageOrFile(for: m, in: directory).lastPathComponent)
            if isAlive(m.pid) && m.pid != getpid() { continue }   // another copy of the app is still recording it
            let media = directory.appendingPathComponent(m.file)
            guard fm.fileExists(atPath: media.path) else { try? fm.removeItem(at: url); continue }
            result.append(Pending(manifest: m, mediaURL: media))
        }
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in items where !referenced.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
        return result.sorted { $0.manifest.startedAt < $1.manifest.startedAt }
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    public struct Salvaged: Sendable {
        public var url: URL
        public var duration: Double
        public var pixelSize: CGSize
    }

    /// Turns an interrupted media file into a clean recording in `recordings`: the readable part is re-muxed
    /// (passthrough, no re-encode); if that fails the raw file is moved there instead, since it already plays.
    /// Returns nil when nothing readable was written (killed before the first fragment).
    public static func salvage(_ pending: Pending, into recordings: URL) async -> Salvaged? {
        let asset = AVURLAsset(url: pending.mediaURL)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        let ext = pending.mediaURL.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        let output = AppPaths.uniqueURL(recordings.appendingPathComponent("\(pending.manifest.name) (recovered)").appendingPathExtension(ext))
        let fm = FileManager.default
        do {
            try await remux(asset, to: output, fileType: ext == "mov" ? .mov : .mp4)
            try? fm.removeItem(at: pending.mediaURL)
            return Salvaged(url: output, duration: duration, pixelSize: size)
        } catch {
            Log.recording.error("Re-muxing the interrupted recording failed, keeping it as is: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: output)
        }
        guard (try? fm.moveItem(at: pending.mediaURL, to: output)) != nil else { return nil }
        return Salvaged(url: output, duration: duration, pixelSize: size)
    }

    private enum RemuxError: Error { case noSession, failed }

    /// Passthrough export (copies the readable samples, no re-encode).
    static func remux(_ asset: AVAsset, to output: URL, fileType: AVFileType) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw RemuxError.noSession }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = fileType == .mp4
        let box = UncheckedBox(session)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.value.exportAsynchronously {
                if box.value.status == .completed { cont.resume() } else { cont.resume(throwing: box.value.error ?? RemuxError.failed) }
            }
        }
    }

    /// Salvages the recorder's own interrupted file (writer failed mid-recording) and removes the leftovers.
    public static func salvage(_ token: Token, into recordings: URL) async -> Salvaged? {
        let result = await salvage(Pending(manifest: token.manifest, mediaURL: token.mediaURL), into: recordings)
        abandon(token)
        return result
    }

    /// Removes what a pending recording left in the in-progress folder (after salvaging, or when it was unusable).
    public static func clear(_ pending: Pending, in directory: URL = directory) {
        try? FileManager.default.removeItem(at: packageOrFile(for: pending.manifest, in: directory))
        try? FileManager.default.removeItem(at: manifestURL(for: pending.manifest.id, in: directory))
    }

    /// Launch-time recovery: every interrupted recording becomes a normal recording and goes through the usual
    /// after-recording flow, after telling the user what happened.
    @MainActor
    public static func recoverAll() async {
        for p in pending() {
            let salvaged = await salvage(p, into: AppPaths.recordings)
            clear(p)
            guard let salvaged else {
                Log.recording.notice("Interrupted recording \(p.manifest.name, privacy: .public) had nothing readable; removed")
                continue
            }
            let when = DateFormatter.localizedString(from: p.manifest.startedAt, dateStyle: .medium, timeStyle: .short)
            let length = Self.formatDuration(salvaged.duration)
            Alerts.info("Recovered recording from \(when)",
                        info: "Super Screenshot stopped unexpectedly while recording. The \(length) captured before that was recovered.")
            MediaPipeline.didFinishRecording(url: salvaged.url, kind: .video, mode: .recording,
                                             pixelSize: salvaged.pixelSize, scale: CGFloat(p.manifest.scale))
        }
    }

    /// `m:ss`, or `h:mm:ss` from one hour (the recording timer's format).
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
