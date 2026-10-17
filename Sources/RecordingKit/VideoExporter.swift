import AVFoundation
import SuperScreenshotCore

struct VideoExportOptions {
    var timeRange: CMTimeRange
    var includeAudio: Bool
    /// Audio gain, 0…1.
    var volume: Float
    var quality: VideoQuality
    /// Resolution factor, 0 < scale ≤ 1.
    var scale: Double
    var fileType: AVFileType

    var changesVolume: Bool { includeAudio && abs(volume - 1) > 0.001 }
    /// Original quality at full size with untouched audio needs no re-encode.
    var isPassthrough: Bool { quality == .original && scale >= 0.999 && !changesVolume }
}

enum VideoExportError: LocalizedError {
    case noVideo, failed(String), cancelled
    var errorDescription: String? {
        switch self {
        case .noVideo: "The source file does not contain a video track."
        case .failed(let m): m.isEmpty ? "Failed to prepare the video composition for export." : m
        case .cancelled: "Export was canceled."
        }
    }
}

/// Trims / strips audio / re-encodes a video file.
enum VideoExporter {
    static func fileType(for url: URL) -> AVFileType { url.pathExtension.lowercased() == "mov" ? .mov : .mp4 }

    /// Builds a composition containing `range` of the asset's video (and, unless removed, audio) tracks.
    static func composition(of asset: AVAsset, range: CMTimeRange, includeAudio: Bool) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw VideoExportError.noVideo }
        let audioTracks = includeAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        for track in videoTracks + audioTracks {
            // A track may start late or end early (e.g. a microphone track); insert only its overlap.
            let overlap = range.intersection(try await track.load(.timeRange))
            guard !overlap.isEmpty,
                  let dst = comp.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try dst.insertTimeRange(overlap, of: track, at: overlap.start - range.start)
            if track.mediaType == .video { dst.preferredTransform = try await track.load(.preferredTransform) }
        }
        return comp
    }

    /// Exports and returns the output's pixel size.
    static func export(source url: URL, options: VideoExportOptions, to output: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        let comp = try await composition(of: asset, range: options.timeRange, includeAudio: options.includeAudio)
        try? FileManager.default.removeItem(at: output)
        if options.isPassthrough {
            try await passthrough(comp, to: output, fileType: options.fileType, progress: progress)
        } else {
            try await Transcoder(asset: comp, options: options, output: output, progress: progress).run()
        }
        let out = AVURLAsset(url: output)
        guard let track = try await out.loadTracks(withMediaType: .video).first else { throw VideoExportError.noVideo }
        let (size, t) = try await track.load(.naturalSize, .preferredTransform)
        let r = size.applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    private static func passthrough(_ asset: AVAsset, to output: URL, fileType: AVFileType,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoExportError.failed("")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = fileType == .mp4
        let box = UncheckedBox(session)
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(box.value.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { poll.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.value.exportAsynchronously {
                    switch box.value.status {
                    case .completed: cont.resume()
                    case .cancelled: cont.resume(throwing: VideoExportError.cancelled)
                    default: cont.resume(throwing: box.value.error ?? VideoExportError.failed(""))
                    }
                }
            }
        } onCancel: { box.value.cancelExport() }
        progress(1)
    }

    /// Estimated output size in bytes for the editor's "Estimated file size" label.
    static func estimatedSize(sourceBytes: Int64, sourceDuration: Double, options: VideoExportOptions,
                              pixelSize: CGSize, fps: Int, audioTracks: Int) -> Int64 {
        let duration = options.timeRange.duration.seconds
        guard duration > 0, sourceDuration > 0 else { return 0 }
        if options.isPassthrough {
            return Int64(Double(sourceBytes) * min(1, duration / sourceDuration))
        }
        let dims = RecordingMath.evenPixelSize(points: pixelSize, scale: CGFloat(options.scale))
        let video = RecordingMath.videoBitrate(width: dims.width, height: dims.height, fps: fps, quality: options.quality)
        // Re-encoding mixes every audio track into one stereo track.
        let audio = options.includeAudio && audioTracks > 0 ? [RecordingMath.audioBitrate(mono: false)] : []
        return RecordingMath.estimatedFileSize(videoBitrate: video, audioBitrates: audio, duration: duration)
    }
}

/// AVAssetReader → AVAssetWriter re-encode with the recording bitrate model.
private final class Transcoder: @unchecked Sendable {
    private let asset: AVAsset
    private let options: VideoExportOptions
    private let output: URL
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "superscreenshot.recording.transcode")
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    // Queue-confined pump state.
    private var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = []
    private var finished: [Bool] = []
    private var duration: Double = 0

    init(asset: AVAsset, options: VideoExportOptions, output: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.asset = asset; self.options = options; self.output = output; self.progress = progress
    }

    func run() async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: options.fileType)
        writer.shouldOptimizeForNetworkUse = options.fileType == .mp4
        self.reader = reader; self.writer = writer

        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw VideoExportError.noVideo }
        let (natural, transform, nominalFPS) = try await vTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let fps = max(1, Int(nominalFPS.rounded()))
        let dims = RecordingMath.evenPixelSize(points: natural, scale: CGFloat(options.scale))
        let codec = RecordingMath.codec(for: options.quality, width: dims.width, height: dims.height)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = []
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        vOut.alwaysCopiesSampleData = false
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: dims.width,
            AVVideoHeightKey: dims.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingMath.videoBitrate(width: dims.width, height: dims.height, fps: fps, quality: options.quality),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        vIn.transform = transform
        guard reader.canAdd(vOut), writer.canAdd(vIn) else { throw VideoExportError.failed("Could not configure the video writer.") }
        reader.add(vOut); writer.add(vIn)
        pairs.append((vOut, vIn, true))

        // Every audio track (system audio + microphone) is mixed into one stereo track at the chosen volume.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let aOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            ])
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(options.volume, at: .zero)
                return p
            }
            aOut.audioMix = mix
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: RecordingMath.audioBitrate(mono: false),
            ])
            if reader.canAdd(aOut), writer.canAdd(aIn) {
                reader.add(aOut); writer.add(aIn)
                pairs.append((aOut, aIn, false))
            }
        }

        guard reader.startReading() else { throw VideoExportError.failed(reader.error?.localizedDescription ?? "Could not create the video reader.") }
        guard writer.startWriting() else { throw VideoExportError.failed(writer.error?.localizedDescription ?? "Could not create the video writer.") }
        writer.startSession(atSourceTime: .zero)

        self.pairs = pairs
        self.finished = Array(repeating: false, count: pairs.count)
        self.duration = duration
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                for i in pairs.indices {
                    group.enter()
                    pairs[i].1.requestMediaDataWhenReady(on: queue) { [self] in
                        if pump(i) { group.leave() }
                    }
                }
                group.notify(queue: queue) { cont.resume() }
            }
        } onCancel: { [self] in
            queue.async { self.reader?.cancelReading() }
        }

        if writer.status == .failed {
            reader.cancelReading()
            throw VideoExportError.failed(writer.error?.localizedDescription ?? "")
        }
        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw VideoExportError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw VideoExportError.failed(reader.error?.localizedDescription ?? "")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw VideoExportError.failed(writer.error?.localizedDescription ?? "") }
        progress(1)
    }

    /// Feeds pair `i` while its input accepts data. Returns true exactly once, when the pair finishes.
    private func pump(_ i: Int) -> Bool {
        guard !finished[i], let reader else { return false }
        let (out, input, isVideo) = pairs[i]
        while input.isReadyForMoreMediaData {
            if reader.status == .reading, let sb = out.copyNextSampleBuffer() {
                if isVideo, duration > 0 { progress(min(1, sb.presentationTimeStamp.seconds / duration)) }
                if !input.append(sb) { reader.cancelReading() }
            } else {
                input.markAsFinished()
                finished[i] = true
                return true
            }
        }
        return false
    }
}
