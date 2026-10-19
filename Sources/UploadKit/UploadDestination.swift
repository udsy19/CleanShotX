import Foundation
import SuperScreenshotCore

/// A file ready to be sent (possibly a down-scaled temp copy of the capture).
public struct UploadItem: Sendable {
    public var fileURL: URL
    public var fileName: String
    public var contentType: String
    public var size: Int64
}

/// Where a file goes, decided before the transfer. For S3 and folders this already yields the link,
/// mirroring CleanShot's "init upload" step that lets the link be copied when the upload starts.
struct UploadReservation: Sendable, Equatable {
    var kind: UploadDestinationKind
    /// S3 object key, or the destination file path for folders; empty for custom HTTP.
    var location: String
    var link: URL?
}

/// One destination snapshot built from the current settings.
enum UploadDestination: Sendable {
    case s3(S3Configuration)
    case http(HTTPEndpointConfiguration)
    case folder(FolderConfiguration)

    var kind: UploadDestinationKind {
        switch self {
        case .s3: .s3
        case .http: .customHTTP
        case .folder: .folder
        }
    }

    /// Whether the selected destination has everything it needs (no network access).
    static var isConfigured: Bool {
        switch Defaults[.uploadDestination] {
        case .none: false
        case .s3: S3Configuration.current().isComplete
        case .customHTTP: HTTPEndpointConfiguration.validEndpoint(Defaults[.customHTTPEndpoint].trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case .folder: !Defaults[.uploadFolderPath].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func current() throws -> UploadDestination {
        switch Defaults[.uploadDestination] {
        case .none: throw UploadError.notConfigured
        case .s3:
            let c = S3Configuration.current()
            try c.validate()
            return .s3(c)
        case .customHTTP: return .http(try HTTPEndpointConfiguration.current())
        case .folder: return .folder(try FolderConfiguration.current())
        }
    }

    /// Picks the remote location. Reusing a previous reservation of the same kind keeps the link stable
    /// when an edited capture is uploaded again ("Update uploaded screenshot").
    func reserve(_ item: UploadItem, reusing previous: UploadReservation?) throws -> UploadReservation {
        if let previous, previous.kind == kind, kind != .customHTTP { return previous }
        switch self {
        case .s3(let c):
            let key = UploadNaming.objectKey(prefix: c.pathPrefix, fileName: item.fileName)
            return UploadReservation(kind: .s3, location: key, link: c.publicURL(key: key))
        case .http:
            return UploadReservation(kind: .customHTTP, location: "", link: nil)
        case .folder(let c):
            let dest = try c.reserveDestination(fileName: item.fileName)
            return UploadReservation(kind: .folder, location: dest.path, link: c.link(for: dest))
        }
    }

    /// Transfers the file; returns the final link. `progress` receives bytes of the file sent so far.
    func transfer(_ item: UploadItem, to reservation: UploadReservation,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        switch self {
        case .s3(let c):
            try await S3Client(config: c).upload(file: item.fileURL, size: item.size, key: reservation.location,
                                                 contentType: item.contentType, progress: progress)
            guard let link = reservation.link else { throw UploadError.failed("Couldn't build a link for the uploaded file.") }
            return link
        case .http(let c):
            return try await HTTPEndpointClient(config: c).upload(file: item.fileURL, fileName: item.fileName,
                                                                  contentType: item.contentType, size: item.size, progress: progress)
        case .folder(let c):
            // Nonisolated async code runs off the main actor, and the copy observes task cancellation.
            try c.copy(item.fileURL, to: URL(fileURLWithPath: reservation.location), progress: progress)
            guard let link = reservation.link else { throw UploadError.failed("Couldn't build a link for the copied file.") }
            return link
        }
    }

    /// Deletes an uploaded file where the destination allows it (used by the connection test).
    func remove(_ reservation: UploadReservation) async throws {
        switch self {
        case .s3(let c): try await S3Client(config: c).deleteObject(key: reservation.location)
        case .http: break // A generic endpoint has no delete API.
        case .folder: try FileManager.default.removeItem(atPath: reservation.location)
        }
    }
}
