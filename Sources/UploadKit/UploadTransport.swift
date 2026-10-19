import Foundation
import SuperScreenshotCore

// MARK: - Failure classification

/// A non-2xx response. Keeps the status so the retry policy and the failure alert can classify it, and builds a
/// readable message from the body (S3 `<Error>` documents, short text/JSON snippets).
public struct UploadHTTPError: LocalizedError, Sendable {
    public let statusCode: Int
    /// Server-provided explanation, if the body had one.
    public let detail: String?

    public init(statusCode: Int, detail: String? = nil) {
        self.statusCode = statusCode
        self.detail = detail
    }

    public init(response: HTTPURLResponse, body: Data) {
        let detail: String?
        if let err = S3XMLResponse(body)?.error {
            detail = "\(err.code): \(err.message)"
        } else if let text = String(data: body.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.hasPrefix("<") {
            detail = text
        } else {
            detail = nil
        }
        self.init(statusCode: response.statusCode, detail: detail)
    }

    /// 401/403: wrong or revoked credentials — retrying can't help, the settings can.
    public var isAuthFailure: Bool { UploadRetryPolicy.isAuthFailure(status: statusCode) }
    /// 429/5xx: the server may accept the same request a moment later.
    public var isTransient: Bool { UploadRetryPolicy.isTransient(status: statusCode) }

    public var errorDescription: String? {
        let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
        var msg = isAuthFailure ? "The destination refused the upload: HTTP \(statusCode) (\(reason))."
                                : "The server responded with HTTP \(statusCode) (\(reason))."
        if let detail { msg += " " + detail }
        if isAuthFailure {
            msg += " Check the credentials in Settings → Upload."
        } else if (300..<400).contains(statusCode), detail == nil {
            msg += " The request was redirected, which usually means a Wi-Fi sign-in page or a wrong endpoint."
        }
        return msg
    }
}

/// When a failed attempt is worth repeating, and how long to wait first: network-level `URLError`s, HTTP 429
/// and 5xx get three retries with growing pauses; auth and other 4xx failures and cancellation never retry.
/// Pure, so the behaviour is checked as a table in the self-tests.
public enum UploadRetryPolicy {
    /// Pause before retry 1, 2 and 3; a fourth failure is final.
    public static let delays: [TimeInterval] = [1, 3, 9]

    static let transientURLErrors: Set<URLError.Code> = [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
        .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .secureConnectionFailed,
    ]

    public static func isTransient(status: Int) -> Bool { status == 429 || (500..<600).contains(status) }
    public static func isAuthFailure(status: Int) -> Bool { status == 401 || status == 403 }

    public static func isTransient(_ error: Error) -> Bool {
        switch error {
        case is CancellationError: false
        case let e as URLError: transientURLErrors.contains(e.code)
        case let e as UploadHTTPError: e.isTransient
        default: false
        }
    }

    /// Pause before the next attempt after the `attempt`-th (1-based) one failed with `error`, or nil to give up.
    public static func shouldRetry(error: Error, attempt: Int, delays: [TimeInterval] = delays) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count, isTransient(error) else { return nil }
        return delays[attempt - 1]
    }
}

// MARK: - Transport

/// Shared HTTP layer for all destinations: one `URLSession`, per-task delegates for byte-level upload progress,
/// and retries per `UploadRetryPolicy` (CleanShot's `sessionRetryable` / `retryCount`).
public final class UploadTransport: @unchecked Sendable {
    public static let shared = UploadTransport()

    public enum Body {
        case none
        case data(Data)
        case file(URL)
    }

    private let session: URLSession
    private let retryDelays: [TimeInterval]
    private let lock = NSLock()
    private var backgroundCount = 0

    /// `configuration` lets the self-tests plug in a stub protocol; `retryDelays` lets them skip the pauses.
    public init(configuration: URLSessionConfiguration = .ephemeral, retryDelays: [TimeInterval] = UploadRetryPolicy.delays) {
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.httpAdditionalHeaders = ["User-Agent": "SuperScreenshot/1.0 (macOS)"]
        session = URLSession(configuration: configuration)
        self.retryDelays = retryDelays
    }

    /// Sends `request`, repeating transient failures. Throws `UploadHTTPError` for a non-2xx response and
    /// `CancellationError` when the task is cancelled. `progress` receives body bytes sent in the current attempt.
    public func send(_ request: URLRequest, body: Body, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                return try await sendOnce(request, body: body, progress: progress)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                guard let delay = UploadRetryPolicy.shouldRetry(error: error, attempt: attempt, delays: retryDelays) else { throw error }
                Log.upload.info("\(request.httpMethod ?? "", privacy: .public) \(request.url?.host ?? "", privacy: .public): \(error.localizedDescription, privacy: .public); retry \(attempt) in \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Fire-and-forget request outside the current task, for cleanup that must outlive a cancelled upload
    /// (aborting a multipart upload). `hasBackgroundWork` stays true until it finishes.
    public func sendInBackground(_ request: URLRequest, body: Body) {
        lock.withLock { backgroundCount += 1 }
        Task.detached { [self] in
            defer { lock.withLock { backgroundCount -= 1 } }
            do {
                _ = try await send(request, body: body)
            } catch {
                Log.upload.notice("Background \(request.httpMethod ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public var hasBackgroundWork: Bool { lock.withLock { backgroundCount > 0 } }

    private func sendOnce(_ request: URLRequest, body: Body, progress: (@Sendable (Int64) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        let delegate = TaskDelegate(onSend: progress)
        let result: (Data, URLResponse)
        switch body {
        case .none: result = try await session.data(for: request, delegate: delegate)
        case .data(let d): result = try await session.upload(for: request, from: d, delegate: delegate)
        case .file(let u): result = try await session.upload(for: request, fromFile: u, delegate: delegate)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw UploadError.failed("The server sent an invalid response.") }
        guard (200..<300).contains(http.statusCode) else { throw UploadHTTPError(response: http, body: result.0) }
        return (result.0, http)
    }
}

/// Per-task delegate: forwards `didSendBodyData` and keeps redirects from hiding failures.
private final class TaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onSend: (@Sendable (Int64) -> Void)?
    init(onSend: (@Sendable (Int64) -> Void)?) { self.onSend = onSend }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSend?(totalBytesSent)
    }

    /// Only method-preserving redirects (307/308) are followed. Anything else — a Wi-Fi sign-in page, S3's
    /// "wrong region" 301 — comes back as the response, instead of a GET of some web page passing as success.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(response.statusCode == 307 || response.statusCode == 308 ? request : nil)
    }
}
