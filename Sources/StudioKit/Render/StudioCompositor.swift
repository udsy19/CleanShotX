import AVFoundation
import CoreImage

/// One instruction per clip: maps composition time back to source time and names the tracks to read.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    /// source seconds = composition seconds + offset
    let sourceOffset: Double
    let box: SceneBox

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, sourceOffset: Double, box: SceneBox) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.sourceOffset = sourceOffset
        self.box = box
        var ids = [NSNumber(value: screenTrackID)]
        if let cameraTrackID { ids.append(NSNumber(value: cameraTrackID)) }
        requiredSourceTrackIDs = ids
    }
}

/// Custom AVVideoCompositing that calls `StudioRenderer` for every frame (used by AVPlayer and AVAssetReader alike).
final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let attributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let sourcePixelBufferAttributes: [String: any Sendable]? = StudioCompositor.attributes
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = StudioCompositor.attributes

    private let queue = DispatchQueue(label: "superscreenshot.studio.compositor", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "StudioCompositor"])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let cancelLock = NSLock()
    private var generation = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        cancelLock.lock(); let gen = generation; cancelLock.unlock()
        queue.async { [self] in
            autoreleasepool {
                cancelLock.lock(); let cancelled = gen != generation; cancelLock.unlock()
                if cancelled { request.finishCancelledRequest(); return }
                guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
                      let out = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "SuperScreenshot.Studio", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: "Failed to prepare the video composition."]))
                    return
                }
                let t = request.compositionTime.seconds + instruction.sourceOffset
                let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
                let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
                let size = request.renderContext.size
                let image = StudioRenderer.render(scene: instruction.box.scene, screen: screen, camera: camera, at: t, canvas: size)
                context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelLock.lock(); generation += 1; cancelLock.unlock()
    }
}

/// The recording's tracks, loaded once per editor.
struct ProjectMedia: @unchecked Sendable {
    let screenAsset: AVURLAsset
    let screenTrack: AVAssetTrack
    let screenRange: CMTimeRange
    let systemAudio: (AVAssetTrack, CMTimeRange)?
    let microphone: (AVAssetTrack, CMTimeRange)?
    let cameraAsset: AVURLAsset?
    let cameraTrack: (AVAssetTrack, CMTimeRange)?
    let frameRate: Float

    static func load(package: StudioPackage, recording: RecordingInfo) async throws -> ProjectMedia {
        let asset = AVURLAsset(url: package.screenURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioPackage.PackageError.unreadable("The source file does not contain a video track.")
        }
        let (trackRange, fps, segments) = try await video.load(.timeRange, .nominalFrameRate, .segments)
        // The writer's session starts at the shared clock's zero and the first screen frame arrives a few
        // milliseconds later, leaving a leading empty edit. Composition time mapped onto it has no source frame,
        // so the paused preview (and an export's first frame) showed only the background. Start at the first sample.
        var range = trackRange
        if let first = segments.first, first.isEmpty, segments.count > 1 {
            range = CMTimeRange(start: first.timeMapping.target.end, end: trackRange.end)
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        var audioRanges: [(AVAssetTrack, CMTimeRange)] = []
        for a in audio { audioRanges.append((a, try await a.load(.timeRange))) }
        var system: (AVAssetTrack, CMTimeRange)?
        var mic: (AVAssetTrack, CMTimeRange)?
        // The recorder adds the system-audio track before the microphone track.
        var queue = audioRanges
        if recording.hasSystemAudio, !queue.isEmpty { system = queue.removeFirst() }
        if recording.hasMicrophone, !queue.isEmpty { mic = queue.removeFirst() }

        var camAsset: AVURLAsset?
        var cam: (AVAssetTrack, CMTimeRange)?
        if package.hasCamera {
            let a = AVURLAsset(url: package.cameraURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            if let t = try? await a.loadTracks(withMediaType: .video).first, let r = try? await t.load(.timeRange) {
                camAsset = a; cam = (t, r)
            }
        }
        return ProjectMedia(screenAsset: asset, screenTrack: video, screenRange: range, systemAudio: system, microphone: mic,
                            cameraAsset: camAsset, cameraTrack: cam, frameRate: fps > 0 ? fps : Float(recording.fps))
    }
}

/// An AVComposition + video composition + audio mix built from the clip list.
struct BuiltComposition: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let duration: CMTime
}

enum CompositionBuilder {
    static let timescale: CMTimeScale = 60000

    static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

    static func build(project: StudioProject, media: ProjectMedia, box: SceneBox, renderSize: CGSize, fps: Int) throws -> BuiltComposition {
        let comp = AVMutableComposition()
        guard let screen = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioPackage.PackageError.unreadable("Failed to prepare the video composition.")
        }
        let camera = media.cameraTrack != nil ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let sys = media.systemAudio != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let mic = media.microphone != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        func insert(_ dest: AVMutableCompositionTrack?, _ src: (AVAssetTrack, CMTimeRange)?, _ range: CMTimeRange, at cursor: CMTime) {
            guard let dest, let (track, avail) = src else { return }
            let r = CMTimeRangeGetIntersection(range, otherRange: avail)
            guard r.duration > .zero else { return }
            try? dest.insertTimeRange(r, of: track, at: cursor + (r.start - range.start))
        }

        var ranges: [(CMTimeRange, Double)] = []
        var cursor = CMTime.zero
        for clip in project.clips.sorted(by: { $0.start < $1.start }) {
            let wanted = CMTimeRange(start: time(clip.start), duration: time(clip.duration))
            let r = CMTimeRangeGetIntersection(wanted, otherRange: media.screenRange)
            guard r.duration > CMTime(value: 1, timescale: 600) else { continue }
            try screen.insertTimeRange(r, of: media.screenTrack, at: cursor)
            insert(camera, media.cameraTrack, r, at: cursor)
            insert(sys, media.systemAudio, r, at: cursor)
            insert(mic, media.microphone, r, at: cursor)
            ranges.append((CMTimeRange(start: cursor, duration: r.duration), r.start.seconds - cursor.seconds))
            cursor = cursor + r.duration
        }
        // Drop empty tracks so readers don't stall on them.
        var cameraID = camera?.trackID
        if let camera, camera.segments.isEmpty { comp.removeTrack(camera); cameraID = nil }
        let instructions = ranges.map {
            StudioInstruction(timeRange: $0.0, screenTrackID: screen.trackID, cameraTrackID: cameraID, sourceOffset: $0.1, box: box)
        }
        guard !instructions.isEmpty else { throw StudioPackage.PackageError.unreadable("The project has no video left to play.") }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = StudioCompositor.self
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        vc.instructions = instructions

        let audio = project.style.audio
        var params: [AVMutableAudioMixInputParameters] = []
        if let sys, !sys.segments.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: sys)
            p.setVolume(audio.systemGain, at: .zero)
            params.append(p)
        }
        if let mic, !mic.segments.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: mic)
            p.setVolume(audio.microphoneGain, at: .zero)
            params.append(p)
        }
        for t in [sys, mic].compactMap({ $0 }) where t.segments.isEmpty { comp.removeTrack(t) }
        var mix: AVMutableAudioMix?
        if !params.isEmpty { mix = AVMutableAudioMix(); mix?.inputParameters = params }
        return BuiltComposition(composition: (comp.copy() as? AVComposition) ?? comp, videoComposition: vc, audioMix: mix, duration: cursor)
    }
}
