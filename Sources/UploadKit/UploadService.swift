import AppKit
import SuperScreenshotCore

extension Defaults.Keys {
    /// Last 50 successful uploads, newest first.
    static let uploadRecentUploads = Key<[UploadRecord]>("upload.recentUploads", default: [])
}

/// `UploadServicing` implementation: queueing, preparation, destination transfer, link handling, recents.
@MainActor
public final class UploadService: UploadServicing {
    public static let shared = UploadService()
    static let maxRecentUploads = 50

    private lazy var queue = UploadQueueController { [unowned self] job in await self.run(job) }
    /// Where each media went this session, so re-uploading an edited capture keeps its link.
    private var reservations: [UUID: UploadReservation] = [:]

    private init() {}

    // MARK: - UploadServicing

    public var isConfigured: Bool { UploadDestination.isConfigured }

    public var recentUploads: [UploadRecord] { Defaults[.uploadRecentUploads] }

    public func upload(_ media: CapturedMedia, progress: ((Double) -> Void)?, completion: ((Result<URL, Error>) -> Void)?) {
        guard isConfigured else {
            completion?(.failure(UploadError.notConfigured))
            presentNotConfigured()
            return
        }
        if let existing = queue.job(for: media) {
            if let progress { existing.progressHandlers.append(progress); progress(existing.fraction) }
            if let completion { existing.completionHandlers.append(completion) }
            return
        }
        let job = UploadJob(media: media, totalBytes: UploadPreparation.fileSize(media.url))
        if let progress { job.progressHandlers.append(progress) }
        if let completion { job.completionHandlers.append(completion) }
        Log.upload.info("Queued upload of \(media.url.lastPathComponent, privacy: .public)")
        queue.enqueue(job)
    }

    public func testConnection(completion: @escaping (Result<URL, Error>) -> Void) {
        Task { @MainActor in
            var probeDir: URL?
            do {
                let destination = try UploadDestination.current()
                let (file, dir) = try Self.makeProbeFile()
                probeDir = dir
                let item = UploadItem(fileURL: file, fileName: file.lastPathComponent, contentType: "image/png",
                                      size: UploadPreparation.fileSize(file))
                let reservation = try destination.reserve(item, reusing: nil)
                let link = try await destination.transfer(item, to: reservation) { _ in }
                do {
                    try await destination.remove(reservation)
                } catch {
                    Log.upload.notice("Test file uploaded but not deleted: \(error.localizedDescription, privacy: .public)")
                }
                if let probeDir { try? FileManager.default.removeItem(at: probeDir) }
                completion(.success(link))
            } catch {
                if let probeDir { try? FileManager.default.removeItem(at: probeDir) }
                Log.upload.error("Connection test failed: \(error.localizedDescription, privacy: .public)")
                completion(.failure(error))
            }
        }
    }

    // MARK: - Public extras (app target / status menu)

    /// True while anything is queued or uploading.
    public var isUploading: Bool { queue.isBusy }

    public func cancel(_ media: CapturedMedia) {
        if let job = queue.job(for: media) { queue.cancel(job) }
    }

    public func cancelAll() { queue.cancelAll() }


    // MARK: - Job execution

    private func run(_ job: UploadJob) async {
        let media = job.media
        var tempDir: URL?
        var copiedAtStart = false
        let result: Result<URL, Error>
        do {
            let destination = try UploadDestination.current()
            let source = media.url, isImage = media.isImage, maxWidth = Defaults[.uploadMaxImageWidth]
            let prepared = try await Task.detached(priority: .userInitiated) {
                try UploadPreparation.prepare(fileURL: source, isImage: isImage, maxWidth: maxWidth)
            }.value
            tempDir = prepared.temporaryDirectory
            try Task.checkCancellation()
            queue.setTotal(job, bytes: prepared.item.size)

            let previous = media.uploadedURL != nil ? reservations[media.id] : nil
            let reservation = try destination.reserve(prepared.item, reusing: previous)
            if Defaults[.uploadCopyLinkWhenStarts], let link = reservation.link {
                copyLink(link)
                copiedAtStart = true
            }
            let jobID = job.id
            let link = try await destination.transfer(prepared.item, to: reservation) { [weak self] sent in
                Task { @MainActor in self?.queue.report(jobID: jobID, sent: sent) }
            }
            try Task.checkCancellation()
            reservations[media.id] = reservation
            result = .success(link)
        } catch {
            result = .failure(job.isCancelled ? CancellationError() : error)
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        finish(job, result, linkAlreadyCopied: copiedAtStart)
    }

    private func finish(_ job: UploadJob, _ result: Result<URL, Error>, linkAlreadyCopied: Bool) {
        let media = job.media
        switch result {
        case .success(let url):
            Log.upload.info("Uploaded \(media.url.lastPathComponent, privacy: .public)")
            media.uploadedURL = url
            media.notifyChanged()
            if !linkAlreadyCopied { copyLink(url) }
            record(UploadRecord(fileName: media.url.lastPathComponent, url: url))
            Sound.play(.uploadDone)
        case .failure(let error):
            if error is CancellationError || job.isCancelled {
                Log.upload.info("Upload of \(media.url.lastPathComponent, privacy: .public) cancelled")
            } else {
                // Async so a modal alert doesn't hold up the next queued upload.
                DispatchQueue.main.async { Alerts.error("There was an error while uploading your file.", error) }
            }
        }
        job.completionHandlers.forEach { $0(result) }
    }

    private func copyLink(_ url: URL) {
        Clipboard.copy(url: url)
        HUD.show("Link has been copied", symbol: "link")
    }

    private func record(_ entry: UploadRecord) {
        var list = Defaults[.uploadRecentUploads].filter { $0.url != entry.url }
        list.insert(entry, at: 0)
        Defaults[.uploadRecentUploads] = Array(list.prefix(Self.maxRecentUploads))
    }

    private func presentNotConfigured() {
        let open = Alerts.confirm("Uploading isn't set up",
                                  info: "Choose where Super Screenshot uploads your captures — S3-compatible storage, your own HTTP endpoint, or a synced folder.",
                                  confirmTitle: "Open Settings", cancelTitle: "Not Now")
        if open { Services.preferences?.show(pane: "upload") }
    }

    /// A tiny generated PNG named `super-screenshot-test.png` in its own temp directory.
    private static func makeProbeFile() throws -> (file: URL, directory: URL) {
        guard let ctx = ImageTools.context(width: 16, height: 16) else { throw UploadError.failed("Couldn't create the test image.") }
        ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.48, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 4, y: 4, width: 8, height: 8))
        guard let image = ctx.makeImage() else { throw UploadError.failed("Couldn't create the test image.") }
        let dir = AppPaths.temporary.appendingPathComponent("Uploads/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = try ImageTools.write(image, to: dir.appendingPathComponent("super-screenshot-test.png"), format: .png)
        return (file, dir)
    }
}
