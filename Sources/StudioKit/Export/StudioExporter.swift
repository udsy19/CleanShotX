import AVFoundation
import CoreImage
import SuperScreenshotCore

/// Renders a project to MP4 (AVAssetReader → custom compositor → AVAssetWriter) or GIF (streamed frame by frame).
///
/// Output is written to a temporary file and moved to `outputURL` only when the export completes, so a
/// cancelled, failed or crashed export never leaves a partial file at the destination.
public final class StudioExporter: @unchecked Sendable {
    public enum ExportError: LocalizedError {
        case cancelled, failed(String)
        public var errorDescription: String? {
            switch self {
            case .cancelled: "Export was canceled."
            case .failed(let m): m
            }
        }
    }

    public let outputURL: URL
    public let outputSize: CGSize
    private let built: BuiltComposition
    private let settings: ExportSettings
    private let lock = NSLock()
    private var _cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var generator: AVAssetImageGenerator?

    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    @MainActor
    init(project: StudioProject, events: StudioEvents, package: StudioPackage, media: ProjectMedia, settings: ExportSettings, outputURL: URL) throws {
        self.settings = settings
        self.outputURL = outputURL
        let base = CanvasLayout.baseCanvasSize(sourceSize: project.recording.pixelSize, style: project.style)
        outputSize = settings.outputSize(base: base)
        let box = SceneBox(RenderScene(project: project, events: events, packageURL: package.url))
        built = try CompositionBuilder.build(project: project, media: media, box: box, renderSize: outputSize, fps: settings.effectiveFPS)
    }

    /// Prepares an export of the project saved in `package` (the editor passes its live state to `init`).
    @MainActor
    public static func load(package: StudioPackage, settings: ExportSettings, outputURL: URL) async throws -> StudioExporter {
        let (project, _) = try package.readProject()
        let media = try await ProjectMedia.load(package: package, recording: project.recording)
        return try StudioExporter(project: project, events: package.readEvents(), package: package, media: media,
                                  settings: settings, outputURL: outputURL)
    }

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        generator?.cancelAllCGImageGeneration()
        reader?.cancelReading()
    }

    /// Runs the export. `progress` (0…1) and `completion` are called on the main queue.
    public func start(progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        let fm = FileManager.default
        let finish: @Sendable (Result<URL, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }
        // Fail before rendering anything when the destination can't take the file.
        let folder = outputURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: outputURL.path, isDirectory: &isDir), isDir.boolValue {
            finish(.failure(ExportError.failed("Cannot save to “\(outputURL.lastPathComponent)”: a folder with that name is in the way.")))
            return
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            finish(.failure(ExportError.failed("Cannot save to the folder “\(folder.lastPathComponent)”. You don't have permission to write there.")))
            return
        }
        let temp = AppPaths.temporary.appendingPathComponent(UUID().uuidString).appendingPathExtension(outputURL.pathExtension)
        let done: @Sendable (Result<Void, Error>) -> Void = { [outputURL] r in
            let fm = FileManager.default
            switch r {
            case .success:
                do {
                    if fm.fileExists(atPath: outputURL.path) {
                        _ = try fm.replaceItemAt(outputURL, withItemAt: temp)
                    } else {
                        try fm.moveItem(at: temp, to: outputURL)
                    }
                    finish(.success(outputURL))
                } catch {
                    try? fm.removeItem(at: temp)
                    finish(.failure(error))
                }
            case .failure(let error):
                try? fm.removeItem(at: temp)
                finish(.failure(error))
            }
        }
        let report: @Sendable (Double) -> Void = { p in DispatchQueue.main.async { progress(min(max(p, 0), 1)) } }
        if settings.format == .gif { exportGIF(to: temp, progress: report, completion: done) } else { exportVideo(to: temp, progress: report, completion: done) }
    }

    // MARK: MP4

    private func exportVideo(to output: URL, progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let comp = built.composition
        let duration = built.duration.seconds
        do {
            let reader = try AVAssetReader(asset: comp)
            let videoTracks = comp.tracks.filter { $0.mediaType == .video }
            let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
            ])
            vOut.videoComposition = built.videoComposition
            vOut.alwaysCopiesSampleData = false
            guard reader.canAdd(vOut) else { throw ExportError.failed("Could not configure the video reader.") }
            reader.add(vOut)

            let audioTracks = comp.tracks.filter { $0.mediaType == .audio }
            var aOut: AVAssetReaderAudioMixOutput?
            if settings.includeAudio, !audioTracks.isEmpty {
                let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
                ])
                o.audioMix = built.audioMix
                if reader.canAdd(o) { reader.add(o); aOut = o }
            }

            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            let format = settings.format
            let fps = settings.effectiveFPS
            let bitrate = EncoderEstimate.videoBitrate(size: outputSize, fps: fps, quality: settings.quality, format: format)
            var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate,
                                              AVVideoExpectedSourceFrameRateKey: fps,
                                              AVVideoMaxKeyFrameIntervalKey: fps * 2]
            if format == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: format == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width), AVVideoHeightKey: Int(outputSize.height),
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
                AVVideoCompressionPropertiesKey: compression,
            ])
            vIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(vIn) else { throw ExportError.failed("Could not configure the video writer.") }
            writer.add(vIn)
            var aIn: AVAssetWriterInput?
            if aOut != nil {
                let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: EncoderEstimate.audioBitrate,
                ])
                i.expectsMediaDataInRealTime = false
                if writer.canAdd(i) { writer.add(i); aIn = i }
            }

            self.reader = reader
            self.writer = writer
            guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Could not create the video reader.") }
            guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "Could not create the video writer.") }
            writer.startSession(atSourceTime: .zero)

            // Each sample is appended inside its own autorelease pool so frames never pile up during a long export.
            let group = DispatchGroup()
            group.enter()
            let vQueue = DispatchQueue(label: "superscreenshot.studio.export.video")
            vIn.requestMediaDataWhenReady(on: vQueue) { [self] in
                while vIn.isReadyForMoreMediaData {
                    let finished: Bool = autoreleasepool {
                        if cancelled { return true }
                        guard let sb = vOut.copyNextSampleBuffer() else { return true }
                        if !vIn.append(sb) { reader.cancelReading(); return true }
                        progress(CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(duration, 0.001))
                        return false
                    }
                    if finished { vIn.markAsFinished(); group.leave(); return }
                }
            }
            if let aIn, let aOut {
                group.enter()
                let aQueue = DispatchQueue(label: "superscreenshot.studio.export.audio")
                aIn.requestMediaDataWhenReady(on: aQueue) { [self] in
                    while aIn.isReadyForMoreMediaData {
                        let finished: Bool = autoreleasepool {
                            if cancelled { return true }
                            guard let sb = aOut.copyNextSampleBuffer() else { return true }
                            return !aIn.append(sb)
                        }
                        if finished { aIn.markAsFinished(); group.leave(); return }
                    }
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) { [self] in
                if cancelled {
                    writer.cancelWriting()
                    completion(.failure(ExportError.cancelled)); return
                }
                if reader.status == .failed || writer.status == .failed {
                    writer.cancelWriting()
                    let msg = (writer.error ?? reader.error)?.localizedDescription ?? "An error occurred while processing the video file."
                    completion(.failure(ExportError.failed(msg))); return
                }
                writer.finishWriting {
                    if writer.status == .completed { progress(1); completion(.success(())) }
                    else { completion(.failure(ExportError.failed(writer.error?.localizedDescription ?? "Failed to write the video."))) }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: GIF

    /// Frames arrive one at a time, in request order, and go straight into a `StreamingGIFWriter`, so a long
    /// project exports with flat memory (a multi-frame `CGImageDestination` would hold every frame until the end).
    private func exportGIF(to output: URL, progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let duration = built.duration.seconds
        let fps = Double(max(1, settings.gifFPS))
        let count = max(1, Int(duration * fps))
        let times = (0..<count).map { NSValue(time: CMTime(seconds: Double($0) / fps, preferredTimescale: CompositionBuilder.timescale)) }
        let writer: StreamingGIFWriter
        do { writer = try StreamingGIFWriter(url: output) } catch { completion(.failure(error)); return }
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        generator = gen
        let state = GIFState(total: count)
        gen.generateCGImagesAsynchronously(forTimes: times) { [self] _, image, _, result, error in
            // The generator calls back serially, so the writer is only ever touched from here.
            let outcome: Result<Void, Error>? = state.withLock { s in
                guard !s.done else { return nil }
                if cancelled || result == .cancelled { s.done = true; return .failure(ExportError.cancelled) }
                if let image {
                    do { try autoreleasepool { try writer.add(image, delay: 1 / fps) }; s.added += 1 }
                    catch { s.done = true; return .failure(error) }
                } else if result == .failed, s.added == 0, s.handled == 0, let error {
                    Log.recording.error("GIF frame failed: \(error.localizedDescription, privacy: .public)")
                }
                s.handled += 1
                progress(Double(s.handled) / Double(s.total))
                guard s.handled == s.total else { return nil }
                s.done = true
                guard s.added > 0 else { return .failure(ExportError.failed("An error occurred while processing the video file.")) }
                do { try writer.finish(); return .success(()) } catch { return .failure(error) }
            }
            guard let outcome else { return }
            if case .failure = outcome {
                writer.abort()
                // Stop generating the remaining frames; not from inside the generator's own callback.
                DispatchQueue.global(qos: .utility).async { gen.cancelAllCGImageGeneration() }
            }
            completion(outcome)
        }
    }
}

/// Counter shared between GIF frame callbacks.
private final class GIFState: @unchecked Sendable {
    struct Value { var total: Int; var handled = 0; var added = 0; var done = false }
    private let lock = NSLock()
    private var value: Value
    init(total: Int) { value = Value(total: total) }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
