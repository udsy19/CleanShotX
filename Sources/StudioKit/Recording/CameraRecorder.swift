import AVFoundation
import ShotcraftCore

/// Records the camera to its own file on the shared recording timeline (FLCameraRecorder).
/// The capture session runs as soon as the recorder is created (for the live preview bubble); frames are
/// written only while the `RecordingClock` is running and not paused.
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CameraError: LocalizedError {
        case notFound, input(String)
        var errorDescription: String? {
            switch self {
            case .notFound: "Camera device not found"
            case .input(let m): "Could not create camera input. \(m)"
            }
        }
    }

    let session = AVCaptureSession()
    let deviceName: String
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "shotcraft.studio.camera", qos: .userInitiated)
    private let hostClock = CMClockGetHostTimeClock()

    // Queue-confined state.
    private var clock: RecordingClock?
    private var url: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var framesWritten = 0
    private var finished = false

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    init(deviceID: String) throws {
        let all = Self.devices()
        guard let device = all.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video) ?? all.first else {
            throw CameraError.notFound
        }
        deviceName = device.localizedName
        super.init()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.input("The camera is busy.") }
            session.addInput(input)
        } catch let e as CameraError { session.commitConfiguration(); throw e } catch {
            session.commitConfiguration(); throw CameraError.input(error.localizedDescription)
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let s = session
        queue.async { s.startRunning() }
    }

    /// Begin writing frames to `url` once `clock` is running.
    func record(to url: URL, clock: RecordingClock) {
        queue.async { self.url = url; self.clock = clock; self.finished = false; self.framesWritten = 0 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, let clock, let url else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = CMSyncConvertTime(pts, from: session.synchronizationClock ?? hostClock, to: hostClock).seconds
        guard let media = clock.mediaTime(forHost: host) else { return }
        if writer == nil {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            setUpWriter(url: url, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        }
        guard let input, input.isReadyForMoreMediaData,
              let copy = retimed(sampleBuffer, to: CMTime(seconds: media, preferredTimescale: 600_000)) else { return }
        if input.append(copy) { framesWritten += 1 }
        else if let err = writer?.error { Log.recording.error("Camera writer error \(err.localizedDescription, privacy: .public)") }
    }

    private func setUpWriter(url: URL, width: Int, height: Int) {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 6),
                                              AVVideoMaxKeyFrameIntervalKey: 60,
                                              AVVideoAllowFrameReorderingKey: false],
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { return }
        w.add(i)
        guard w.startWriting() else { return }
        w.startSession(atSourceTime: .zero)
        writer = w; input = i
    }

    /// Stops writing. Calls back (on an arbitrary queue) with true if a usable file was produced.
    func finish(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            finished = true
            session.stopRunning()
            guard let writer, let input, framesWritten > 0, writer.status == .writing else {
                writer?.cancelWriting()
                if let url { try? FileManager.default.removeItem(at: url) }
                completion(false); return
            }
            input.markAsFinished()
            writer.finishWriting { completion(writer.status == .completed) }
        }
    }

    /// Discards anything written; `stopSession` also turns the camera off (otherwise the preview keeps running).
    func cancel(stopSession: Bool = true) {
        queue.async { [self] in
            finished = true
            if stopSession { session.stopRunning() }
            writer?.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
            writer = nil; input = nil; url = nil; clock = nil
        }
    }
}
