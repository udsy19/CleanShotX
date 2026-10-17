import AppKit
import AVFoundation
import Combine
import ShotcraftCore

/// Live preview (FLPlayerController): an AVPlayer whose item uses the Studio compositor. Style edits swap
/// the render scene in place; clip edits rebuild the composition.
@MainActor
final class PlayerController {
    let player = AVPlayer()
    private let model: EditorModel
    private let box: SceneBox
    private(set) var media: ProjectMedia?
    private(set) var built: BuiltComposition?
    private var builtClips: [StudioClip] = []
    private var builtCanvas: CGSize = .zero
    private var builtAudio: AudioSettings?
    private var cancellables: Set<AnyCancellable> = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var isSeeking = false
    private var chaseTime = CMTime.zero
    private var refreshPending = false
    /// While true the periodic observer doesn't overwrite the model's playhead (user is scrubbing).
    var isScrubbing = false
    var onReady: (() -> Void)?
    var onCanvasChange: ((CGSize) -> Void)?

    /// Preview frames are rendered at most this large.
    static let maxPreviewSize = CGSize(width: 1920, height: 1200)

    init(model: EditorModel) {
        self.model = model
        box = SceneBox(RenderScene(project: model.project, events: model.events, packageURL: model.package.url))
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.isSeeking, self.player.rate != 0 else { return }
                self.model.playhead = min(max(0, t.seconds), self.model.duration)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.model.isPlaying = playing }
        }
        // @Published emits before the value is stored; hop a turn so `model.project` is the new value.
        model.$project
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.projectChanged() } }
            .store(in: &cancellables)
    }

    func invalidate() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        cancellables.removeAll()
        player.replaceCurrentItem(with: nil)
    }

    func load() async throws {
        let m = try await ProjectMedia.load(package: model.package, recording: model.project.recording)
        media = m
        try rebuild()
        onReady?()
    }

    /// Canvas size used for the live preview.
    var previewCanvas: CGSize {
        let base = CanvasLayout.baseCanvasSize(sourceSize: model.project.recording.pixelSize, style: model.project.style)
        return CanvasLayout.fitted(base, within: Self.maxPreviewSize)
    }

    var currentScene: RenderScene { box.scene }

    private func projectChanged() {
        let p = model.project
        box.scene = RenderScene(project: p, events: model.events, packageURL: model.package.url, reuse: box.scene)
        if p.clips != builtClips || previewCanvas != builtCanvas || p.style.audio != builtAudio {
            try? rebuild()
        } else {
            refreshFrame()
        }
    }

    private func rebuild() throws {
        guard let media else { return }
        let p = model.project
        let canvas = previewCanvas
        let b = try CompositionBuilder.build(project: p, media: media, box: box, renderSize: canvas, fps: p.recording.fps)
        let item = AVPlayerItem(asset: b.composition)
        item.videoComposition = b.videoComposition
        item.audioMix = b.audioMix
        item.seekingWaitsForVideoCompositionRendering = true
        let wasPlaying = player.rate != 0
        let time = CMTime(seconds: min(model.playhead, b.duration.seconds), preferredTimescale: CompositionBuilder.timescale)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.playhead = self.model.duration
            }
        }
        built = b
        builtClips = p.clips
        builtAudio = p.style.audio
        if canvas != builtCanvas { builtCanvas = canvas; onCanvasChange?(canvas) }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    /// Re-renders the paused frame after a style change (coalesced to one in flight).
    func refreshFrame() {
        guard player.rate == 0, let item = player.currentItem, let vc = built?.videoComposition else { return }
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                item.videoComposition = (vc.mutableCopy() as? AVVideoComposition) ?? vc
                self.seek(toOutput: self.model.playhead)
            }
        }
    }

    // MARK: Transport

    /// Frame-accurate "chase" seeking: never more than one seek in flight, always ending on the latest target.
    func seek(toOutput t: Double) {
        let clamped = min(max(0, t), model.duration)
        model.playhead = clamped
        chaseTime = CMTime(seconds: clamped, preferredTimescale: CompositionBuilder.timescale)
        if !isSeeking { performChase() }
    }

    private func performChase() {
        isSeeking = true
        let target = chaseTime
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CMTimeCompare(target, self.chaseTime) == 0 { self.isSeeking = false } else { self.performChase() }
            }
        }
    }

    func togglePlay() {
        if player.rate != 0 { pause(); return }
        play(rate: 1)
    }

    func play(rate: Float) {
        if model.playhead >= model.duration - 0.05 { seek(toOutput: 0) }
        if rate < 0, !(player.currentItem?.canPlayReverse ?? false) { NSSound.beep(); return }
        player.rate = rate
    }

    func pause() {
        player.pause()
        model.playhead = min(max(0, player.currentTime().seconds), model.duration)
    }

    func step(frames: Int) {
        pause()
        seek(toOutput: model.playhead + Double(frames) * model.frameDuration)
    }

    /// Renders the frame at the playhead with the full composition (Export Current Frame).
    func currentFrameImage(canvas: CGSize) async -> CGImage? {
        guard let media else { return nil }
        let exportBox = SceneBox(box.scene)
        guard let b = try? CompositionBuilder.build(project: model.project, media: media, box: exportBox, renderSize: canvas, fps: model.project.recording.fps) else { return nil }
        let gen = AVAssetImageGenerator(asset: b.composition)
        gen.videoComposition = b.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = CMTime(seconds: min(model.playhead, max(0, b.duration.seconds - 0.001)), preferredTimescale: CompositionBuilder.timescale)
        return try? await gen.image(at: t).image
    }

    /// Raw screen frame at a source time (zoom position control thumbnail).
    func sourceThumbnail(at seconds: Double, maxSize: CGSize) async -> CGImage? {
        guard let media else { return nil }
        let gen = AVAssetImageGenerator(asset: media.screenAsset)
        gen.maximumSize = maxSize
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        return try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

/// Hosts the AVPlayerLayer with the composition's aspect ratio; clicking the camera toggles full screen.
final class PreviewView: NSView {
    let playerLayer = AVPlayerLayer()
    var canvasSize = CGSize(width: 16, height: 9) { didSet { needsLayout = true } }
    /// Called with a canvas-pixel point (bottom-left origin) on click.
    var onClick: ((CGPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.cornerRadius = 6
        playerLayer.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    var videoRect: CGRect {
        let inset = bounds.insetBy(dx: 16, dy: 16)
        guard canvasSize.width > 0, canvasSize.height > 0, inset.width > 0, inset.height > 0 else { return inset }
        let f = min(inset.width / canvasSize.width, inset.height / canvasSize.height)
        let w = canvasSize.width * f, h = canvasSize.height * f
        return CGRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h).integral
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = videoRect
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect
        guard r.contains(p) else { return }
        onClick?(CGPoint(x: (p.x - r.minX) / r.width * canvasSize.width, y: (p.y - r.minY) / r.height * canvasSize.height))
    }
}
