import Foundation
import SuperScreenshotCore

/// Shared HTTP layer for all destinations: one `URLSession`, per-task delegates for byte-level upload
/// progress, and retries with back-off for transient failures (CleanShot's `sessionRetryable` / `retryCount`).
final class UploadTransport: @unchecked Sendable {
    static let shared = UploadTransport()

    enum Body {
        case none
        case data(Data)
        case file(URL)
    }

    private let session: URLSession
    private let maxRetries = 2
    private static let retryableStatus: Set<Int> = [429, 500, 502, 503, 504]
    private static let retryableErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                                              .dnsLookupFailed, .cannotFindHost]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.httpAdditionalHeaders = ["User-Agent": "SuperScreenshot/1.0 (macOS)"]
        session = URLSession(configuration: config)
    }

    /// Sends `request` (retrying transient failures). `progress` receives total body bytes sent in the current attempt.
    func send(_ request: URLRequest, body: Body, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await sendOnce(request, body: body, progress: progress)
                if Self.retryableStatus.contains(response.statusCode) && attempt < maxRetries {
                    attempt += 1
                    Log.upload.info("HTTP \(response.statusCode) for \(request.httpMethod ?? "", privacy: .public); retry \(attempt)")
                    try await backoff(attempt)
                    continue
                }
                return (data, response)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where Self.retryableErrors.contains(error.code) && attempt < maxRetries {
                attempt += 1
                Log.upload.info("\(error.localizedDescription, privacy: .public); retry \(attempt)")
                try await backoff(attempt)
            }
        }
    }

    private func sendOnce(_ request: URLRequest, body: Body, progress: (@Sendable (Int64) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        let delegate = progress.map(TaskProgressDelegate.init)
        let result: (Data, URLResponse)
        switch body {
        case .none: result = try await session.data(for: request, delegate: delegate)
        case .data(let d): result = try await session.upload(for: request, from: d, delegate: delegate)
        case .file(let u): result = try await session.upload(for: request, fromFile: u, delegate: delegate)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw UploadError.failed("The server sent an invalid response.") }
        return (result.0, http)
    }

    private func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
    }

    /// Readable failure for a non-2xx response; `detail` is a server-provided message if any.
    static func statusError(_ response: HTTPURLResponse, detail: String?) -> UploadError {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized
        var msg = "The server responded with HTTP \(response.statusCode) (\(reason))."
        if let detail, !detail.isEmpty { msg += " " + detail }
        return .failed(msg)
    }
}

/// Per-task delegate forwarding `didSendBodyData` to a closure.
private final class TaskProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onSend: @Sendable (Int64) -> Void
    init(_ onSend: @escaping @Sendable (Int64) -> Void) { self.onSend = onSend }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSend(totalBytesSent)
    }
}
