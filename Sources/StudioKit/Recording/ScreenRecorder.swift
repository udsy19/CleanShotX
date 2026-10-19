import AVFoundation
import ScreenCaptureKit
import SuperScreenshotCore

/// Studio Mode screen capture (the "Motion" recorder with recordInStudioMode = true): ScreenCaptureKit at
/// native resolution with the cursor hidden, system audio and microphone on separate tracks of screen.mov.
///
/// Threading: all sample callbacks (screen, system audio, microphone) arrive on `queue` and all writer state
/// is confined to it.
final class StudioScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {
    struct Config: @unchecked Sendable {
        var url: URL
        var filter: SCContentFilter
        /// Display-local rect in points.
        var sourceRect: CGRect
        var pixelWidth: Int
        var pixelHeight: Int
        var fps: Int
        var systemAudio: Bool
        var microphoneID: String?
        var mono: Bool
    }

    enum RecorderError: LocalizedError {
        case writer(String), microphone(String)
        var errorDescription: String? {
            switch self {
            case .writer(let m): "Could not create the video writer. \(m)"
            case .microphone(let m): "Microphone error. \(m)"
            }
        }
    }

    let config: Config
    let clock: RecordingClock
    private let queue = DispatchQueue(label: "superscreenshot.studio.screen", qos: .userInteractive)
    private let hostClock = CMClockGetHostTimeClock()
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    /// The microphone session's clock, fixed before the session starts delivering samples.
    private var micClock: CMClock?
    private(set) var microphoneName: String?

    // Queue-confined.
    private var writer: AVAssetWriter!
    private var videoInput: AVAssetWriterInput!
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var lastVideo: CMSampleBuffer?
    private var lastVideoTime = -1.0
    /// Newest frame delivered before the clock started. ScreenCaptureKit only sends frames when the screen
    /// changes, so this is what the first second(s) of a static screen look like.
    private var pendingFirst: CMSampleBuffer?
    private var lastAudioEnd: [ObjectIdentifier: Double] = [:]
    private var accepting = true
    private(set) var videoFrames = 0

    var onFailure: (@Sendable (Error) -> Void)?

    init(config: Config, clock: RecordingClock) {
        self.config = config
        self.clock = clock
    }

    static func codec(width: Int, height: Int) -> AVVideoCodecType {
        (width > 4096 || height > 2304) ? .hevc : .h264
    }

    private func makeWriter() throws {
        let w = try AVAssetWriter(outputURL: config.url, fileType: .mov)
        // Movie fragments: a crash or force quit leaves screen.mov readable up to the last fragment.
        w.movieFragmentInterval = RecordingRecovery.fragmentInterval
        let bitrate = min(150_000_000, max(10_000_000, Int(Double(config.pixelWidth * config.pixelHeight * config.fps) * 0.12)))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: Self.codec(width: config.pixelWidth, height: config.pixelHeight),
            AVVideoWidthKey: config.pixelWidth,
            AVVideoHeightKey: config.pixelHeight,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                                              AVVideoExpectedSourceFrameRateKey: config.fps,
                                              AVVideoMaxKeyFrameIntervalKey: config.fps,
                                              AVVideoAllowFrameReorderingKey: false],
        ])
        video.expectsMediaDataInRealTime = true
        guard w.canAdd(video) else { throw RecorderError.writer("Video input rejected.") }
        w.add(video)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: config.mono ? 1 : 2,
            AVEncoderBitRateKey: config.mono ? 96_000 : 160_000,
        ]
        if config.systemAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); systemInput = a }
        }
        if config.microphoneID != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); micInput = a }
        }
        guard w.startWriting() else { throw RecorderError.writer(w.error?.localizedDescription ?? "") }
        w.startSession(atSourceTime: .zero)
        writer = w; videoInput = video
    }

    private func startMicrophone() throws {
        guard let id = config.microphoneID else { return }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == id }) ?? AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.microphone("No microphone found.")
        }
        microphoneName = device.localizedName
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw RecorderError.microphone(error.localizedDescription) }
        guard session.canAddInput(input) else { throw RecorderError.microphone("The microphone is busy.") }
        session.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                             AVNumberOfChannelsKey: config.mono ? 1 : 2, AVLinearPCMBitDepthKey: 16,
                             AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false]
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw RecorderError.microphone("Could not read the microphone.") }
        session.addOutput(out)
        session.commitConfiguration()
        micClock = session.synchronizationClock ?? hostClock
        micSession = session
        session.startRunning()
    }

    /// Starts capturing. Samples are only written once `clock` has been started.
    func start() async throws {
        try queue.sync { try makeWriter() }
        let c = SCStreamConfiguration()
        c.sourceRect = config.sourceRect
        c.width = config.pixelWidth
        c.height = config.pixelHeight
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        c.showsCursor = false
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.queueDepth = 6
        c.scalesToFit = false
        if config.systemAudio {
            c.capturesAudio = true
            c.excludesCurrentProcessAudio = true
            c.sampleRate = 48_000
            c.channelCount = config.mono ? 1 : 2
        }
        let s = SCStream(filter: config.filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        stream = s
        try startMicrophone()
        try await s.startCapture()
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sb.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            appendVideo(sb)
        case .audio:
            if let systemInput { appendAudio(sb, to: systemInput, hostTime: CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        default:
            break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting, let micInput, let micClock else { return }
        let host = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sb), from: micClock, to: hostClock).seconds
        appendAudio(sb, to: micInput, hostTime: host)
    }

    private func appendVideo(_ sb: CMSampleBuffer) {
        let host = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        guard let t = clock.mediaTime(forHost: host) else {
            if !clock.isStarted { pendingFirst = sb }
            return
        }
        // The video must start at 0 (events.json and camera.mov do): hold the last pre-start frame until the
        // first post-start one.
        if videoFrames == 0, t > 0.0005 { appendPendingFirst() }
        guard t > lastVideoTime else { return }
        append(sb, at: t)
    }

    private func appendPendingFirst() {
        guard let first = pendingFirst else { return }
        pendingFirst = nil
        append(first, at: 0)
    }

    private func append(_ sb: CMSampleBuffer, at t: Double) {
        guard videoInput.isReadyForMoreMediaData, let copy = retimed(sb, to: CMTime(seconds: t, preferredTimescale: 600_000)) else { return }
        if videoInput.append(copy) {
            lastVideo = copy; lastVideoTime = t; videoFrames += 1
        } else if writer.status == .failed, accepting {
            accepting = false
            onFailure?(writer.error ?? RecorderError.writer("Error with processing video buffer."))
        }
    }

    private func appendAudio(_ sb: CMSampleBuffer, to input: AVAssetWriterInput, hostTime: Double) {
        guard let t = clock.mediaTime(forHost: hostTime), input.isReadyForMoreMediaData else { return }
        let key = ObjectIdentifier(input)
        // Never let audio go backwards (can happen right after a resume).
        if let end = lastAudioEnd[key], t < end - 0.001 { return }
        guard let copy = retimed(sb, to: CMTime(seconds: t, preferredTimescale: 48_000)) else { return }
        if input.append(copy) { lastAudioEnd[key] = t + CMSampleBufferGetDuration(sb).seconds }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard accepting else { return }
            accepting = false
            onFailure?(error)
        }
    }

    // MARK: Stop

    /// Stops capture and finalizes screen.mov. `duration` is the clock's final media time.
    func finish(duration: Double) async throws {
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                accepting = false
                // Nothing changed on screen since the start: the pre-start frame is the whole video.
                if videoFrames == 0, writer?.status == .writing { appendPendingFirst() }
                pendingFirst = nil
                guard let writer, writer.status == .writing, videoFrames > 0 else {
                    // A failed writer keeps what it already flushed (salvaged by the session); an empty one is cancelled.
                    if writer?.status != .failed { writer?.cancelWriting() }
                    cont.resume(throwing: RecorderError.writer(writer?.error?.localizedDescription ?? "No frames were recorded."))
                    return
                }
                // Hold the last frame until the end so the video lasts as long as the recording.
                if let last = lastVideo, duration > lastVideoTime + 0.001, videoInput.isReadyForMoreMediaData,
                   let tail = retimed(last, to: CMTime(seconds: duration, preferredTimescale: 600_000)) {
                    videoInput.append(tail)
                }
                lastVideo = nil
                videoInput.markAsFinished()
                systemInput?.markAsFinished()
                micInput?.markAsFinished()
                writer.endSession(atSourceTime: CMTime(seconds: max(duration, lastVideoTime), preferredTimescale: 600_000))
                writer.finishWriting {
                    if writer.status == .completed { cont.resume() }
                    else { cont.resume(throwing: writer.error ?? RecorderError.writer("Failed to finish writing.")) }
                }
            }
        }
    }

    /// Stops everything and deletes the output.
    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                accepting = false
                writer?.cancelWriting()
                lastVideo = nil
                pendingFirst = nil
                try? FileManager.default.removeItem(at: config.url)
                cont.resume()
            }
        }
    }
}
