import Foundation
import SuperScreenshotCore

/// One capture being uploaded. Extra `upload(...)` calls for the same media attach their handlers here.
@MainActor
final class UploadJob {
    let id = UUID()
    let media: CapturedMedia
    var progressHandlers: [(Double) -> Void] = []
    var completionHandlers: [(Result<URL, Error>) -> Void] = []
    /// Bytes to send (file size, refined after preparation).
    var totalBytes: Int64
    var sentBytes: Int64 = 0
    var isCancelled = false
    var task: Task<Void, Never>?
    fileprivate var lastReported: Double = -1

    init(media: CapturedMedia, totalBytes: Int64) {
        self.media = media
        self.totalBytes = max(totalBytes, 1)
    }

    var fraction: Double { min(1, Double(sentBytes) / Double(max(totalBytes, 1))) }
}

/// Serial upload queue (CleanShot's `UploadQueueController`): one transfer at a time, the rest wait.
/// Aggregates byte progress over the current batch into the menu-bar indicator, nil when idle.
@MainActor
final class UploadQueueController {
    /// Performs a job end-to-end, including success/failure handling. Must not throw.
    typealias Runner = (UploadJob) async -> Void

    private(set) var jobs: [UploadJob] = []
    private var running: UploadJob?
    /// Bytes of jobs already finished in the current batch (keeps the aggregate from jumping backwards).
    private var finishedBytes: Int64 = 0
    private let runner: Runner

    init(runner: @escaping Runner) { self.runner = runner }

    var isBusy: Bool { !jobs.isEmpty }

    func job(for media: CapturedMedia) -> UploadJob? { jobs.first { $0.media == media } }

    func enqueue(_ job: UploadJob) {
        jobs.append(job)
        publishAggregate()
        startNextIfIdle()
    }

    func cancel(_ job: UploadJob) {
        job.isCancelled = true
        if let task = job.task {
            task.cancel()
        } else {
            // Not started yet: drop it and report the cancellation directly.
            jobs.removeAll { $0 === job }
            job.completionHandlers.forEach { $0(.failure(CancellationError())) }
            publishAggregate()
        }
    }

    func cancelAll() { jobs.forEach(cancel) }

    func setTotal(_ job: UploadJob, bytes: Int64) {
        job.totalBytes = max(bytes, 1)
        publishAggregate()
    }

    /// Bytes sent so far for the job with `id` (called from transfer callbacks, possibly out of order).
    func report(jobID: UUID, sent: Int64) {
        guard let job = jobs.first(where: { $0.id == jobID }), !job.isCancelled else { return }
        job.sentBytes = max(job.sentBytes, min(sent, job.totalBytes))
        let f = job.fraction
        if f - job.lastReported >= 0.005 || (f >= 1 && job.lastReported < 1) {
            job.lastReported = f
            job.progressHandlers.forEach { $0(f) }
            NotificationCenter.default.post(name: UploadKitModule.progressNotification, object: job.media, userInfo: ["fraction": f])
            publishAggregate()
        }
    }

    // MARK: - Private

    private func startNextIfIdle() {
        guard running == nil, let next = jobs.first(where: { !$0.isCancelled }) else { return }
        running = next
        next.progressHandlers.forEach { $0(0) }
        next.task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runner(next)
            self.jobDidEnd(next)
        }
    }

    private func jobDidEnd(_ job: UploadJob) {
        jobs.removeAll { $0 === job }
        running = nil
        if !job.isCancelled { finishedBytes += job.totalBytes }
        if jobs.isEmpty { finishedBytes = 0 }
        publishAggregate()
        startNextIfIdle()
    }

    private func publishAggregate() {
        guard !jobs.isEmpty else { StatusBar.setProgress(nil); return }
        let sent = finishedBytes + jobs.reduce(0) { $0 + $1.sentBytes }
        let total = finishedBytes + jobs.reduce(0) { $0 + $1.totalBytes }
        StatusBar.setProgress(total > 0 ? min(1, Double(sent) / Double(total)) : 0)
    }
}
