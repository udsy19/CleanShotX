import AVFoundation
import SuperScreenshotCore

/// Crash recovery for recordings: in-progress bookkeeping, the launch-time scan and salvaging an abandoned writer.
/// Everything runs in temporary folders with synthetic frames; no screen or audio is captured.
func registerRecoveryTests() {
    func tempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ss-recovery-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func manifest(_ file: String, pid: Int32 = Int32.max, name: String = "Screen Recording 2026-10-19") -> RecordingRecovery.Manifest {
        RecordingRecovery.Manifest(kind: .video, mode: .recording, name: name, file: file,
                                   pixelSize: CGSize(width: 320, height: 240), scale: 2, pid: pid)
    }
    /// Appends `seconds` of synthetic frames with movie fragments and abandons the writer (no `finishWriting`),
    /// exactly what a crash leaves behind. The writer is kept alive so its deinit can't tidy up like a real crash can't.
    func writeAbandoned(to url: URL, seconds: Int, fileType: AVFileType = .mp4) throws {
        let w = try AVAssetWriter(outputURL: url, fileType: fileType)
        w.movieFragmentInterval = RecordingRecovery.fragmentInterval
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 400_000, AVVideoMaxKeyFrameIntervalKey: 10,
                                              AVVideoAllowFrameReorderingKey: false]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        w.add(input)
        guard w.startWriting() else { throw w.error ?? CocoaError(.fileWriteUnknown) }
        w.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        let fps = 10
        for i in 0..<(fps * seconds) {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), Int32(i * 7 % 255), CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        usleep(1_500_000)   // let the encoder flush its fragments to disk
        AbandonedWriters.keep.append(w)
    }

    SelfTest.cases.append(("Recovery.bookkeeping", {
        let dir = tempDir("book"), out = tempDir("book-out")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
        let fm = FileManager.default
        do {
            let flat = try RecordingRecovery.begin(manifest("a.mp4"), in: dir)
            check(fm.fileExists(atPath: dir.appendingPathComponent("\(flat.manifest.id.uuidString).json").path), "manifest written")
            try Data([1, 2, 3]).write(to: flat.mediaURL)
            let existing = out.appendingPathComponent("Clip.mp4")
            try Data([9]).write(to: existing)
            let final = RecordingRecovery.complete(flat, movingTo: existing)
            check(final.lastPathComponent == "Clip 2.mp4" && fm.fileExists(atPath: final.path), "finished file moved to a unique name: \(final.lastPathComponent)")
            check((try? Data(contentsOf: existing)) == Data([9]), "an existing file is never overwritten")
            check(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty, "manifest cleared after completion")

            let nested = try RecordingRecovery.begin(manifest("pkg.superscreenshotvideo/screen.mov"), in: dir)
            check(fm.fileExists(atPath: nested.mediaURL.deletingLastPathComponent().path), "package folder created for a nested file")
            try Data([1]).write(to: nested.mediaURL)
            RecordingRecovery.abandon(nested)
            check(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty, "abandon removes the package folder and manifest")

            let kept = try RecordingRecovery.begin(manifest("b.mp4"), in: dir)
            try Data([1]).write(to: kept.mediaURL)
            let unwritable = tempDir("book-ro")
            defer { chmod(unwritable.path, 0o700); try? fm.removeItem(at: unwritable) }
            chmod(unwritable.path, 0o500)
            let stayed = RecordingRecovery.complete(kept, movingTo: unwritable.appendingPathComponent("x.mp4"))
            check(stayed == kept.mediaURL && fm.fileExists(atPath: stayed.path), "a failed move keeps the file where it is")
        } catch { check(false, "threw \(error)") }
    }))

    SelfTest.cases.append(("Recovery.pending", {
        let dir = tempDir("pending")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        do {
            let dead = try RecordingRecovery.begin(manifest("dead.mp4"), in: dir)
            try Data([1]).write(to: dead.mediaURL)
            let alive = try RecordingRecovery.begin(manifest("alive.mp4", pid: getppid()), in: dir)
            try Data([1]).write(to: alive.mediaURL)
            let gone = try RecordingRecovery.begin(manifest("gone.mp4"), in: dir)   // media never written
            try Data("{not json".utf8).write(to: dir.appendingPathComponent("corrupt.json"))
            let stale = dir.appendingPathComponent("orphan-old.mp4"), fresh = dir.appendingPathComponent("orphan-new.mp4")
            try Data([1]).write(to: stale); try Data([1]).write(to: fresh)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: stale.path)

            let pending = RecordingRecovery.pending(in: dir)
            check(pending.map(\.manifest.id) == [dead.manifest.id], "only the dead process's recording is pending: \(pending.map(\.manifest.file))")
            check(pending.first?.mediaURL == dead.mediaURL, "pending points at the media file")
            check(fm.fileExists(atPath: alive.mediaURL.path), "a live process's recording is left alone")
            check(!fm.fileExists(atPath: dir.appendingPathComponent("\(gone.manifest.id.uuidString).json").path), "manifest without media removed")
            check(!fm.fileExists(atPath: dir.appendingPathComponent("corrupt.json").path), "corrupt manifest removed")
            check(!fm.fileExists(atPath: stale.path) && fm.fileExists(atPath: fresh.path), "old unreferenced files swept, recent ones kept")
            check(RecordingRecovery.pending(in: dir, isAlive: { _ in true }).isEmpty, "alive filter honoured")
            RecordingRecovery.clear(pending[0], in: dir)
            check(!fm.fileExists(atPath: dead.mediaURL.path), "clear removes the media")
        } catch { check(false, "threw \(error)") }
        check(!RecordingRecovery.processIsAlive(Int32.max) && RecordingRecovery.processIsAlive(getpid()), "process liveness")
        check(RecordingRecovery.formatDuration(62) == "1:02" && RecordingRecovery.formatDuration(3661) == "1:01:01", "duration text")
    }))

    SelfTest.cases.append(("Recovery.salvageAbandonedWriter", {
        let dir = tempDir("salvage"), recordings = tempDir("salvage-out")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: recordings) }
        let fm = FileManager.default
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                // mp4 and mov, the two containers the recorders write.
                for ext in ["mp4", "mov"] {
                    let token = try RecordingRecovery.begin(manifest("clip.\(ext)", name: "Clip"), in: dir)
                    try writeAbandoned(to: token.mediaURL, seconds: 5, fileType: ext == "mov" ? .mov : .mp4)
                    let pending = RecordingRecovery.pending(in: dir)
                    check(pending.count == 1, "abandoned \(ext) recording is pending")
                    guard let p = pending.first else { return }
                    let salvaged = await RecordingRecovery.salvage(p, into: recordings)
                    RecordingRecovery.clear(p, in: dir)
                    check(salvaged != nil, "abandoned \(ext) writer salvaged")
                    guard let salvaged else { continue }
                    check(salvaged.url.lastPathComponent == "Clip (recovered).\(ext)", "recovered name: \(salvaged.url.lastPathComponent)")
                    check(salvaged.duration >= 2 && salvaged.duration <= 5, "readable up to the last fragment: \(salvaged.duration)s")
                    check(salvaged.pixelSize == CGSize(width: 320, height: 240), "pixel size from the track")
                    let reread = try await AVURLAsset(url: salvaged.url).load(.duration).seconds
                    check(abs(reread - salvaged.duration) < 0.01, "re-muxed file plays: \(reread)s")
                    check(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty, "in-progress folder clean after \(ext)")
                }
                // Killed before the first fragment: nothing readable, nothing delivered, nothing left behind.
                let empty = try RecordingRecovery.begin(manifest("empty.mp4"), in: dir)
                try Data(repeating: 0, count: 4096).write(to: empty.mediaURL)
                let p = RecordingRecovery.pending(in: dir)
                let garbage = await RecordingRecovery.salvage(p[0], into: recordings)
                check(garbage == nil, "garbage file is not salvaged")
                RecordingRecovery.clear(p[0], in: dir)
                check(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty, "garbage removed")
                check((try? fm.contentsOfDirectory(atPath: recordings.path))?.count == 2, "exactly the two recovered files delivered")
            } catch { check(false, "threw \(error)") }
        }
        check(sem.wait(timeout: .now() + 120) == .success, "salvage finished in time")
    }))
}

/// Writers deliberately left unfinished by the tests (a crashed process never finalizes either).
enum AbandonedWriters {
    nonisolated(unsafe) static var keep: [AVAssetWriter] = []
}
