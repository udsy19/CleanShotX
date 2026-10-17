import AVFoundation
import CoreMedia
import VideoToolbox
import ScreenCaptureKit
import ShotcraftCore

/// Everything the engine needs, resolved on the main actor before recording starts.
struct CaptureEngineConfig: @unchecked Sendable {
    var outputURL: URL
    var fileType: AVFileType
    var codec: RecordingMath.Codec
    var pixelWidth: Int
    var pixelHeight: Int
    var fps: Int
    var bitrate: Int
    var showsCursor: Bool
    var systemAudio: Bool
    /// `uniqueID` of the microphone, nil = no microphone track.
    var microphoneID: String?
    var mono: Bool
    var filter: SCContentFilter
    /// Display-local rect in points.
    var sourceRect: CGRect
}

enum CaptureEngineError: LocalizedError {
    case writerSetup(String), noFrames, microphone(String), diskFull
    var errorDescription: String? {
        switch self {
        case .writerSetup(let m): "Could not create the video writer. \(m)"
        case .noFrames: "Screen Recording stopped unexpectedly."
        case .microphone(let m): "Microphone error. \(m)"
        case .diskFull: "Recording stopped because your disk is almost full."
        }
    }
}

/// ScreenCaptureKit stream → AVAssetWriter.
///
/// Threading: every sample callback (screen, system audio, microphone) is delivered on `queue`, and every
/// piece of writer state is touched only on `queue`. Public methods hop onto it.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
                           @unchecked Sendable {
    private let config: CaptureEngineConfig
    private let queue = DispatchQueue(label: "shotcraft.recording.samples", qos: .userInteractive)
    private let hostClock = CMClockGetHostTimeClock()

    private var stream: SCStream?
    private var streamConfig = SCStreamConfiguration()
    private var micSession: AVCaptureSession?

    // Queue-confined writer state.
    private var writer: AVAssetWriter!
    private var videoInput: AVAssetWriterInput!
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var accepting = true
    private var paused = false
    private var pauseStartedAt = CMTime.invalid
    private var pauseOffset = CMTime.zero
    private var lastPTS: [ObjectIdentifier: CMTime] = [:]
    private var lastVideoEnd = CMTime.invalid

    /// Called (on an arbitrary queue) when the stream dies or writing fails mid-recording.
    var onFailure: (@Sendable (Error) -> Void)?

    init(config: CaptureEngineConfig) {
        self.config = config
    }

    // MARK: Lifecycle

    func start() async throws {
        try makeWriter()

        let c = SCStreamConfiguration()
        c.sourceRect = config.sourceRect
        c.width = config.pixelWidth
        c.height = config.pixelHeight
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, config.fps)))
        c.queueDepth = 6
        c.showsCursor = config.showsCursor
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.colorSpaceName = CGColorSpace.sRGB
        c.scalesToFit = false
        if config.systemAudio {
            c.capturesAudio = true
            c.excludesCurrentProcessAudio = true
            c.sampleRate = 48_000
            c.channelCount = config.mono ? 1 : 2
        }
        streamConfig = c

        let stream = SCStream(filter: config.filter, configuration: c, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream

        if let micID = config.microphoneID { try startMicrophone(uniqueID: micID) }
        do {
            try await stream.startCapture()
        } catch {
            micSession?.stopRunning()
            try? FileManager.default.removeItem(at: config.outputURL)
            throw error
        }
    }

    private func makeWriter() throws {
        try? FileManager.default.removeItem(at: config.outputURL)
        let w: AVAssetWriter
        do { w = try AVAssetWriter(outputURL: config.outputURL, fileType: config.fileType) } catch {
            throw CaptureEngineError.writerSetup(error.localizedDescription)
        }
        w.shouldOptimizeForNetworkUse = config.fileType == .mp4

        let isHEVC = config.codec == .hevc
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: config.bitrate,
            AVVideoExpectedSourceFrameRateKey: config.fps,
            AVVideoMaxKeyFrameIntervalKey: config.fps * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        compression[AVVideoProfileLevelKey] = isHEVC ? (kVTProfileLevel_HEVC_Main_AutoLevel as String)
                                                     : AVVideoProfileLevelH264HighAutoLevel
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: config.pixelWidth,
            AVVideoHeightKey: config.pixelHeight,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        guard w.canAdd(video) else { throw CaptureEngineError.writerSetup("Unsupported video settings.") }
        w.add(video)
        videoInput = video

        func audioInput() -> AVAssetWriterInput? {
            let channels = config.mono ? 1 : 2
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: RecordingMath.audioBitrate(mono: config.mono),
            ])
            input.expectsMediaDataInRealTime = true
            guard w.canAdd(input) else { return nil }
            w.add(input)
            return input
        }
        if config.systemAudio { systemAudioInput = audioInput() }
        if config.microphoneID != nil { micInput = audioInput() }

        guard w.startWriting() else {
            throw CaptureEngineError.writerSetup(w.error?.localizedDescription ?? "")
        }
        writer = w
    }

    private func startMicrophone(uniqueID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) ?? AVCaptureDevice.default(for: .audio) else {
            throw CaptureEngineError.microphone("No microphone was selected for this recording.")
        }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw CaptureEngineError.microphone(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw CaptureEngineError.microphone("Audio input error") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: config.mono ? 1 : 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureEngineError.microphone("Audio settings error") }
        session.addOutput(output)
        session.startRunning()
        micSession = session
    }

    // MARK: Control

    func setPaused(_ pause: Bool) {
        let now = CMClockGetTime(hostClock)
        queue.async { [self] in
            guard pause != paused else { return }
            if pause {
                paused = true
                pauseStartedAt = now
            } else {
                if pauseStartedAt.isValid { pauseOffset = pauseOffset + (now - pauseStartedAt) }
                pauseStartedAt = .invalid
                paused = false
            }
        }
    }

    func setShowsCursor(_ shows: Bool) {
        guard let stream, streamConfig.showsCursor != shows else { return }
        streamConfig.showsCursor = shows
        stream.updateConfiguration(streamConfig) { error in
            if let error { Log.recording.error("updateConfiguration failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Stops capture and finalizes the file.
    func finish() async throws -> URL {
        let stopTime = CMClockGetTime(hostClock)
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        micSession = nil

        let w: AVAssetWriter? = await withCheckedContinuation { cont in
            queue.async { [self] in
                accepting = false
                guard sessionStarted, writer.status == .writing else {
                    writer?.cancelWriting()
                    cont.resume(returning: nil)
                    return
                }
                // End at the stop time (minus pauses) so a static screen still yields the full duration.
                let endHost = paused && pauseStartedAt.isValid ? pauseStartedAt : stopTime
                var end = endHost - pauseOffset
                if lastVideoEnd.isValid && end < lastVideoEnd { end = lastVideoEnd }
                videoInput.markAsFinished()
                systemAudioInput?.markAsFinished()
                micInput?.markAsFinished()
                writer.endSession(atSourceTime: end)
                cont.resume(returning: writer)
            }
        }
        guard let w else {
            try? FileManager.default.removeItem(at: config.outputURL)
            throw CaptureEngineError.noFrames
        }
        await w.finishWriting()
        if w.status != .completed {
            throw w.error ?? CaptureEngineError.writerSetup("")
        }
        return config.outputURL
    }

    /// Stops and discards everything written so far.
    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        micSession = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                accepting = false
                if writer?.status == .writing { writer.cancelWriting() }
                cont.resume()
            }
        }
        try? FileManager.default.removeItem(at: config.outputURL)
    }

    // MARK: Samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: if let input = systemAudioInput { handleAudio(sampleBuffer, input: input, pts: sampleBuffer.presentationTimeStamp) }
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let input = micInput, sampleBuffer.isValid else { return }
        // Convert from the capture session's clock to the host clock SCK timestamps use.
        var pts = sampleBuffer.presentationTimeStamp
        if let clock = micSession?.synchronizationClock {
            pts = CMSyncConvertTime(pts, from: clock, to: hostClock)
        }
        handleAudio(sampleBuffer, input: input, pts: pts)
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard accepting, !paused, writer.status == .writing else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        let pts = sb.presentationTimeStamp - pauseOffset
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        append(sb, to: videoInput, pts: pts)
        lastVideoEnd = pts
    }

    private func handleAudio(_ sb: CMSampleBuffer, input: AVAssetWriterInput, pts hostPTS: CMTime) {
        guard accepting, !paused, sessionStarted, writer.status == .writing else { return }
        append(sb, to: input, pts: hostPTS - pauseOffset)
    }

    private func append(_ sb: CMSampleBuffer, to input: AVAssetWriterInput, pts: CMTime) {
        let key = ObjectIdentifier(input)
        if let last = lastPTS[key], pts <= last { return }   // keep each track monotonic
        guard input.isReadyForMoreMediaData else { return }
        var buffer = sb
        if pts != sb.presentationTimeStamp {
            guard let retimed = retime(sb, to: pts) else { return }
            buffer = retimed
        }
        if input.append(buffer) {
            lastPTS[key] = pts
        } else if writer.status == .failed {
            accepting = false
            let error = writer.error ?? CaptureEngineError.writerSetup("")
            Log.recording.error("Writer failed: \(error.localizedDescription, privacy: .public)")
            onFailure?(error)
        }
    }

    private func retime(_ sb: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        let delta = pts - sb.presentationTimeStamp
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: timings.count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid { timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + delta }
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp + delta }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                              sampleTimingEntryCount: timings.count, sampleTimingArray: &timings,
                                              sampleBufferOut: &out)
        return out
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.recording.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
        onFailure?(error)
    }
}
