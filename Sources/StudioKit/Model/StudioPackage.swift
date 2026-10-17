import Foundation

/// On-disk layout of a `.superscreenshotvideo` project package (FLDocument):
///
///     <name>.superscreenshotvideo/
///       screen.mov      screen video (no cursor) + system-audio and microphone tracks
///       camera.mov      optional camera recording on the same timeline
///       events.json     cursor / click / scroll / key events (StudioEvents)
///       project.json    edits + style (StudioProject)
///       autosave.json   unsaved edits (crash recovery), removed on save / discard
///       background.*    optional user-chosen background image
public struct StudioPackage: Sendable {
    public static let fileExtension = "superscreenshotvideo"
    /// Packages recorded before the app was renamed from Shotcraft: same layout, still opened.
    public static let legacyFileExtension = "shotcraftvideo"
    public static let screenFile = "screen.mov"
    public static let cameraFile = "camera.mov"
    public static let eventsFile = "events.json"
    public static let projectFile = "project.json"
    public static let autosaveFile = "autosave.json"

    public enum PackageError: LocalizedError {
        case unreadable(String), unwritable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let m): "Failed to read the video project package. \(m)"
            case .unwritable(let m): "Failed to write the video project package. \(m)"
            }
        }
    }

    public var url: URL
    public init(url: URL) { self.url = url }

    public var screenURL: URL { url.appendingPathComponent(Self.screenFile) }
    public var cameraURL: URL { url.appendingPathComponent(Self.cameraFile) }
    public var eventsURL: URL { url.appendingPathComponent(Self.eventsFile) }
    public var projectURL: URL { url.appendingPathComponent(Self.projectFile) }
    public var autosaveURL: URL { url.appendingPathComponent(Self.autosaveFile) }
    public var hasCamera: Bool { FileManager.default.fileExists(atPath: cameraURL.path) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode(_ project: StudioProject) throws -> Data { try encoder.encode(project) }
    public static func decodeProject(_ data: Data) throws -> StudioProject { try decoder.decode(StudioProject.self, from: data) }

    public func readProject() throws -> (project: StudioProject, recovered: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: screenURL.path) else { throw PackageError.unreadable("screen.mov is missing.") }
        if let data = try? Data(contentsOf: autosaveURL), let p = try? Self.decodeProject(data) { return (p, true) }
        do {
            return (try Self.decodeProject(Data(contentsOf: projectURL)), false)
        } catch {
            throw PackageError.unreadable("Failed to decode the project data. \(error.localizedDescription)")
        }
    }

    public func readEvents() -> StudioEvents {
        guard let data = try? Data(contentsOf: eventsURL), let e = try? Self.decoder.decode(StudioEvents.self, from: data) else { return StudioEvents() }
        return e
    }

    public func write(project: StudioProject) throws {
        do {
            try Self.encode(project).write(to: projectURL, options: .atomic)
            try? FileManager.default.removeItem(at: autosaveURL)
        } catch { throw PackageError.unwritable(error.localizedDescription) }
    }

    public func autosave(project: StudioProject) {
        try? Self.encode(project).write(to: autosaveURL, options: .atomic)
    }

    public func discardAutosave() { try? FileManager.default.removeItem(at: autosaveURL) }

    public func write(events: StudioEvents) throws {
        do { try Self.encoder.encode(events).write(to: eventsURL, options: .atomic) }
        catch { throw PackageError.unwritable(error.localizedDescription) }
    }

    public func resolve(backgroundFile name: String) -> URL { url.appendingPathComponent(name) }
}
