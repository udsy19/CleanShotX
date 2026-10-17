import Foundation
import CoreGraphics
import SuperScreenshotCore

/// One persisted Capture History record.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var kind: MediaKind
    public var mode: CaptureMode
    public var date: Date
    public var width: Double
    public var height: Double
    public var scale: Double
    public var isSaved: Bool
    public var uploadedURL: URL?
    public var projectURL: URL?

    public init(id: UUID, url: URL, kind: MediaKind, mode: CaptureMode, date: Date, width: Double, height: Double,
                scale: Double, isSaved: Bool, uploadedURL: URL? = nil, projectURL: URL? = nil) {
        self.id = id; self.url = url; self.kind = kind; self.mode = mode; self.date = date
        self.width = width; self.height = height; self.scale = scale; self.isSaved = isSaved
        self.uploadedURL = uploadedURL; self.projectURL = projectURL
    }

    public init(_ media: CapturedMedia) {
        self.init(id: media.id, url: media.url, kind: media.kind, mode: media.mode, date: media.createdAt,
                  width: Double(media.pixelSize.width), height: Double(media.pixelSize.height),
                  scale: Double(media.scale), isSaved: media.isSaved,
                  uploadedURL: media.uploadedURL, projectURL: media.projectURL)
    }

    public func makeMedia() -> CapturedMedia {
        let m = CapturedMedia(id: id, url: url, kind: kind, mode: mode, createdAt: date,
                              pixelSize: CGSize(width: width, height: height), scale: CGFloat(scale), isSaved: isSaved)
        m.uploadedURL = uploadedURL
        m.projectURL = projectURL
        return m
    }
}

/// Pure persistence + retention logic for Capture History.
public enum HistoryIndex {
    public static let currentVersion = 1

    private struct File: Codable {
        var version: Int
        var items: [HistoryEntry]
    }

    public static func encode(_ entries: [HistoryEntry]) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(dateFormatter().string(from: date))
        }
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(File(version: currentVersion, items: entries))
    }

    /// Decodes an index file. Unknown/corrupt items are skipped rather than discarding the whole history.
    public static func decode(_ data: Data) -> [HistoryEntry] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = dateFormatter().date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date \(s)")
        }
        if let file = try? dec.decode(File.self, from: data) { return sortedNewestFirst(file.items) }
        // Lenient fallback: decode item by item.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [Any] else { return [] }
        let entries = items.compactMap { item -> HistoryEntry? in
            guard let d = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? dec.decode(HistoryEntry.self, from: d)
        }
        return sortedNewestFirst(entries)
    }

    /// ISO-8601 with milliseconds, so ordering of captures taken within the same second survives a round-trip.
    private static func dateFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    public static func sortedNewestFirst(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.sorted { $0.date > $1.date }
    }

    public struct PruneResult: Equatable {
        public var kept: [HistoryEntry]
        /// Older than the retention window.
        public var expired: [HistoryEntry]
        /// The file no longer exists.
        public var missing: [HistoryEntry]
    }

    /// Splits entries into kept / expired / missing. `retentionDays <= 0` keeps everything that still exists.
    public static func prune(_ entries: [HistoryEntry], now: Date, retentionDays: Int,
                             fileExists: (URL) -> Bool) -> PruneResult {
        let cutoff: Date? = retentionDays > 0 ? now.addingTimeInterval(-Double(retentionDays) * 86_400) : nil
        var result = PruneResult(kept: [], expired: [], missing: [])
        for e in entries {
            if !fileExists(e.url) { result.missing.append(e) }
            else if let cutoff, e.date < cutoff { result.expired.append(e) }
            else { result.kept.append(e) }
        }
        return result
    }

    /// Only unsaved captures that still live in one of the app-managed folders are ever deleted.
    public static func shouldDeleteFile(of entry: HistoryEntry, managedDirectories: [URL]) -> Bool {
        guard !entry.isSaved else { return false }
        let path = entry.url.standardizedFileURL.path
        return managedDirectories.contains { dir in
            let d = dir.standardizedFileURL.path
            return path.hasPrefix(d.hasSuffix("/") ? d : d + "/")
        }
    }

    /// Inserts or replaces (same id) and keeps newest-first order.
    public static func upsert(_ entry: HistoryEntry, into entries: [HistoryEntry]) -> [HistoryEntry] {
        var out = entries.filter { $0.id != entry.id }
        out.append(entry)
        return sortedNewestFirst(out)
    }

    public enum Filter: String, CaseIterable, Sendable {
        case all, screenshots, videos, gifs
        public var title: String {
            switch self {
            case .all: "All"
            case .screenshots: "Screenshots"
            case .videos: "Videos"
            case .gifs: "GIFs"
            }
        }
        public func matches(_ kind: MediaKind) -> Bool {
            switch self {
            case .all: true
            case .screenshots: kind == .image
            case .videos: kind == .video || kind == .studioProject
            case .gifs: kind == .gif
            }
        }
    }
}
