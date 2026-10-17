import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import SuperScreenshotCore

/// Renders a project to MP4 (AVAssetReader → custom compositor → AVAssetWriter) or GIF (FLVideoEncoder).
final class StudioExporter: @unchecked Sendable {
    enum ExportError: LocalizedError {
        case cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: "Export was canceled."
            case .failed(let m): m
            }
        }
    }

    let outputURL: URL
    let outputSize: CGSize
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

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        generator?.cancelAllCGImageGeneration()
        reader?.cancelReading()
    }

    /// Runs the export. `progress` (0…1) and `completion` are called on the main queue.
    func start(progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        try? FileManager.default.removeItem(at: outputURL)
        let done: @Sendable (Result<URL, Error>) -> Void = { [outputURL] r in
            if case .failure = r { try? FileManager.default.removeItem(at: outputURL) }
            DispatchQueue.main.async { completion(r) }
        }
        let report: @Sendable (Double) -> Void = { p in DispatchQueue.main.async { progress(min(max(p, 0), 1)) } }
        if settings.format == .gif { exportGIF(progress: report, completion: done) } else { exportVideo(progress: report, completion: done) }
    }

    // MARK: MP4

    private func exportVideo(progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
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

            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
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

            let group = DispatchGroup()
            group.enter()
            let vQueue = DispatchQueue(label: "superscreenshot.studio.export.video")
            vIn.requestMediaDataWhenReady(on: vQueue) { [self] in
                while vIn.isReadyForMoreMediaData {
                    if cancelled { vIn.markAsFinished(); group.leave(); return }
                    guard let sb = vOut.copyNextSampleBuffer() else { vIn.markAsFinished(); group.leave(); return }
                    if !vIn.append(sb) { reader.cancelReading(); vIn.markAsFinished(); group.leave(); return }
                    progress(CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(duration, 0.001))
                }
            }
            if let aIn, let aOut {
                group.enter()
                let aQueue = DispatchQueue(label: "superscreenshot.studio.export.audio")
                aIn.requestMediaDataWhenReady(on: aQueue) { [self] in
                    while aIn.isReadyForMoreMediaData {
                        if cancelled { aIn.markAsFinished(); group.leave(); return }
                        guard let sb = aOut.copyNextSampleBuffer() else { aIn.markAsFinished(); group.leave(); return }
                        if !aIn.append(sb) { aIn.markAsFinished(); group.leave(); return }
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
                writer.finishWriting { [outputURL] in
                    if writer.status == .completed { progress(1); completion(.success(outputURL)) }
                    else { completion(.failure(ExportError.failed(writer.error?.localizedDescription ?? "Failed to write the video."))) }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: GIF

    private func exportGIF(progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        let duration = built.duration.seconds
        let fps = Double(max(1, settings.gifFPS))
        let count = max(1, Int(duration * fps))
        let times = (0..<count).map { NSValue(time: CMTime(seconds: Double($0) / fps, preferredTimescale: CompositionBuilder.timescale)) }
        guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            completion(.failure(ExportError.failed("Could not create the GIF file."))); return
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        generator = gen
        let state = GIFState(total: count)
        // Results arrive in request order on a background queue.
        gen.generateCGImagesAsynchronously(forTimes: times) { [self] _, image, _, result, error in
            let finished: Bool = state.withLock {
                guard !$0.done else { return false }
                if cancelled || result == .cancelled { $0.done = true; completion(.failure(ExportError.cancelled)); return false }
                if let image { CGImageDestinationAddImage(dest, image, frameProps); $0.added += 1 }
                else if result == .failed, $0.added == 0, $0.handled == 0, let error { Log.recording.error("GIF frame failed: \(error.localizedDescription, privacy: .public)") }
                $0.handled += 1
                progress(Double($0.handled) / Double($0.total))
                if $0.handled == $0.total { $0.done = true; return true }
                return false
            }
            guard finished else { return }
            if state.withLock({ $0.added }) > 0, CGImageDestinationFinalize(dest) { completion(.success(outputURL)) }
            else { completion(.failure(ExportError.failed("An error occurred while processing the video file."))) }
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
