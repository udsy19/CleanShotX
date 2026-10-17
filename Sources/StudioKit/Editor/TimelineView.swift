import AppKit
import AVFoundation
import Combine
import ShotcraftCore

/// Video thumbnails for the clip track (FLThumbnailGenerator), generated lazily for visible tiles.
@MainActor
final class ThumbnailProvider {
    private let generator: AVAssetImageGenerator
    private var cache: [Int: CGImage] = [:]
    private var order: [Int] = []
    private var pending: Set<Int> = []
    private var queued: [Int] = []
    var onUpdate: () -> Void = {}

    init(asset: AVAsset) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 240, height: 150)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
    }

    /// Thumbnail near source time `t` (quantized to milliseconds of `step`); requests it if missing.
    func image(at t: Double, step: Double) -> CGImage? {
        let q = max(step, 0.05)
        let key = Int(((t / q).rounded() * q) * 1000)
        if let img = cache[key] { return img }
        if !pending.contains(key) { pending.insert(key); queued.append(key) }
        return nil
    }

    /// Sends the tiles requested during the last draw as one batch.
    func flush() {
        guard !queued.isEmpty else { return }
        let keys = queued
        queued = []
        let times = keys.map { NSValue(time: CMTime(value: CMTimeValue($0), timescale: 1000)) }
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, _, _ in
            let key = Int(requested.value * 1000 / CMTimeValue(max(requested.timescale, 1)))
            let img = image
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending.remove(key)
                    guard let img else { return }
                    self.cache[key] = img
                    self.order.append(key)
                    if self.order.count > 500 { self.cache[self.order.removeFirst()] = nil }
                    self.onUpdate()
                }
            }
        }
    }

    func cancel() { generator.cancelAllCGImageGeneration() }
}

/// Scroll view that turns vertical wheel motion into horizontal scrolling and ⌘-scroll into timeline zoom.
final class TimelineScrollView: NSScrollView {
    var onZoom: ((Double, CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let anchor = documentView?.convert(event.locationInWindow, from: nil).x ?? 0
            onZoom?(event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1, anchor)
            return
        }
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let doc = documentView {
            var origin = contentView.bounds.origin
            origin.x = min(max(0, origin.x - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)),
                           max(0, doc.frame.width - contentView.bounds.width))
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
            return
        }
        super.scrollWheel(with: event)
    }
}

/// The timeline (FLTimeline): ruler, clip track with thumbnails, zoom track, camera full-screen track, playhead.
/// x positions are output-timeline seconds; zoom/camera segments live in source time and are mapped through clips.
@MainActor
final class TimelineView: NSView {
    enum Lane { case zoom, camera }

    private let model: EditorModel
    private weak var player: PlayerController?
    var thumbnails: ThumbnailProvider?
    private(set) var geometry = TimelineGeometry(pixelsPerSecond: 60)
    private var cancellables: Set<AnyCancellable> = []
    private let playheadView = PlayheadView()
    private var hoverX: CGFloat?
    private var dragCounter = 0

    // Layout (flipped, top-left origin).
    let rulerHeight: CGFloat = 24
    private var clipRect: (y: CGFloat, h: CGFloat) { (32, 60) }
    private var zoomRect: (y: CGFloat, h: CGFloat) { (100, 30) }
    private var cameraRect: (y: CGFloat, h: CGFloat) { (138, 24) }
    var contentHeight: CGFloat { model.hasCamera ? 172 : 140 }

    init(model: EditorModel, player: PlayerController) {
        self.model = model
        self.player = player
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 172))
        wantsLayer = true
        addSubview(playheadView)
        model.$project.receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.contentChanged() } }.store(in: &cancellables)
        model.$selection.receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } }.store(in: &cancellables)
        model.$playhead.receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.playheadMoved() } }.store(in: &cancellables)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    private var visibleWidth: CGFloat { enclosingScrollView?.contentView.bounds.width ?? bounds.width }

    // MARK: Scale

    func contentChanged() {
        updateWidth()
        needsDisplay = true
        playheadMoved()
    }

    func updateWidth() {
        let w = max(visibleWidth, CGFloat(geometry.x(for: model.duration)) + 40)
        let h = max(contentHeight, enclosingScrollView?.contentView.bounds.height ?? contentHeight)
        if frame.width != w || frame.height != h { setFrameSize(NSSize(width: w, height: h)) }
    }

    func zoomToFit() {
        geometry = TimelineGeometry.fitting(duration: model.duration, width: Double(visibleWidth))
        updateWidth()
        enclosingScrollView?.contentView.scroll(to: .zero)
        needsDisplay = true
        playheadMoved()
    }

    /// Multiplies the scale keeping the time under `anchorX` (document coords) in place; nil anchors on the playhead.
    func zoom(by factor: Double, anchorX: CGFloat? = nil) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let anchor = anchorX ?? CGFloat(geometry.x(for: model.playhead))
        let anchorTime = geometry.time(for: Double(anchor))
        let screenOffset = anchor - clip.bounds.origin.x
        geometry.pixelsPerSecond = TimelineGeometry.clampScale(geometry.pixelsPerSecond * factor)
        updateWidth()
        let newX = CGFloat(geometry.x(for: anchorTime)) - screenOffset
        clip.scroll(to: NSPoint(x: min(max(0, newX), max(0, frame.width - clip.bounds.width)), y: 0))
        enclosingScrollView?.reflectScrolledClipView(clip)
        needsDisplay = true
        playheadMoved()
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + Double(event.magnification), anchorX: convert(event.locationInWindow, from: nil).x)
    }

    private func playheadMoved() {
        let x = CGFloat(geometry.x(for: model.playhead))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playheadView.frame = NSRect(x: x - 7, y: 0, width: 14, height: bounds.height)
        CATransaction.commit()
        // Keep the playhead visible while playing.
        if model.isPlaying, let clip = enclosingScrollView?.contentView {
            let vis = clip.bounds
            if x > vis.maxX - 20 || x < vis.minX {
                clip.scroll(to: NSPoint(x: min(max(0, x - vis.width * 0.1), max(0, frame.width - vis.width)), y: 0))
                enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
    }

    // MARK: Mapping

    private func outputRange<S: LaneSegment>(_ s: S) -> (Double, Double)? {
        let tl = model.timeline
        let a = tl.outputTimeClamped(forSource: s.start, preferLater: true)
        let b = tl.outputTimeClamped(forSource: s.end, preferLater: false)
        return b - a > 0.01 ? (a, b) : nil
    }

    private func laneRect(_ lane: Lane) -> NSRect {
        let r = lane == .zoom ? zoomRect : cameraRect
        return NSRect(x: 0, y: r.y, width: bounds.width, height: r.h)
    }

    private func segmentRect(start: Double, end: Double, lane: Lane) -> NSRect {
        let l = laneRect(lane)
        let x0 = CGFloat(geometry.x(for: start)), x1 = CGFloat(geometry.x(for: end))
        return NSRect(x: x0, y: l.minY, width: max(2, x1 - x0), height: l.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        drawRuler(dirtyRect)
        drawClips(dirtyRect)
        drawLane(.zoom)
        if model.hasCamera { drawLane(.camera) }
        if let hx = hoverX {
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
            NSRect(x: hx - 0.5, y: rulerHeight, width: 1, height: bounds.height - rulerHeight).fill()
        }
        thumbnails?.flush()
    }

    private func drawRuler(_ dirty: NSRect) {
        let step = geometry.rulerStep
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        let t0 = max(0, (geometry.time(for: Double(dirty.minX) - 40) / step).rounded(.down) * step)
        let t1 = min(model.duration, geometry.time(for: Double(dirty.maxX) + 40))
        var t = t0
        NSColor.tertiaryLabelColor.setFill()
        while t <= t1 + 1e-9 {
            let x = CGFloat(geometry.x(for: t))
            NSRect(x: x, y: rulerHeight - 8, width: 1, height: 8).fill()
            let minor = CGFloat(geometry.x(for: t + step / 2))
            if t + step / 2 <= model.duration { NSRect(x: minor, y: rulerHeight - 4, width: 1, height: 4).fill() }
            (TimeFormat.string(t, tenths: step < 1) as NSString).draw(at: NSPoint(x: x + 3, y: 3), withAttributes: attrs)
            t += step
        }
        // Cut marks where the source jumps between clips.
        let clips = model.project.clips
        let starts = model.timeline.outputStarts
        for i in 1..<max(clips.count, 1) where abs(clips[i].start - clips[i - 1].end) > 0.01 {
            let x = CGFloat(geometry.x(for: starts[i]))
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [.systemOrange]))
            if let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cut")?.withSymbolConfiguration(config) {
                img.draw(in: NSRect(x: x - 6, y: rulerHeight - 14, width: 12, height: 12))
            }
        }
    }

    private func drawClips(_ dirty: NSRect) {
        let starts = model.timeline.outputStarts
        let (y, h) = clipRect
        for (i, clip) in model.project.clips.enumerated() {
            let x0 = CGFloat(geometry.x(for: starts[i])), w = CGFloat(geometry.width(for: clip.duration))
            let r = NSRect(x: x0 + 1, y: y, width: max(2, w - 2), height: h)
            guard r.intersects(dirty) else { continue }
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            NSColor(white: 0.12, alpha: 1).setFill()
            path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if let thumbs = thumbnails {
                let aspect = Double(model.project.recording.pixelWidth) / Double(max(model.project.recording.pixelHeight, 1))
                let tileW = max(30, Double(h) * aspect)
                let stepSec = tileW / geometry.pixelsPerSecond
                var tx = Double(x0)
                while tx < Double(x0 + w) {
                    if tx + tileW >= Double(dirty.minX) && tx <= Double(dirty.maxX) {
                        let mid = geometry.time(for: tx + tileW / 2) - starts[i]
                        let src = clip.start + min(max(0, mid), clip.duration)
                        if let img = thumbs.image(at: src, step: stepSec), let ctx = NSGraphicsContext.current?.cgContext {
                            ctx.saveGState()
                            ctx.translateBy(x: CGFloat(tx), y: y + h); ctx.scaleBy(x: 1, y: -1)
                            ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(tileW), height: h))
                            ctx.restoreGState()
                        }
                    }
                    tx += tileW
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let selected = model.selection == .clip(clip.id)
            let border = NSBezierPath(roundedRect: r.insetBy(dx: selected ? 1.25 : 0.5, dy: selected ? 1.25 : 0.5), xRadius: 8, yRadius: 8)
            border.lineWidth = selected ? 2.5 : 1
            (selected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.15)).setStroke()
            border.stroke()
            // Trim handles.
            if selected || (hoverX.map { $0 >= r.minX && $0 <= r.maxX } ?? false) {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX + 3, y: r.midY - 10, width: 3, height: 20), xRadius: 1.5, yRadius: 1.5).fill()
                NSBezierPath(roundedRect: NSRect(x: r.maxX - 6, y: r.midY - 10, width: 3, height: 20), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    private func drawLane(_ lane: Lane) {
        let l = laneRect(lane)
        let track = NSRect(x: CGFloat(geometry.x(for: 0)), y: l.minY, width: CGFloat(geometry.width(for: model.duration)), height: l.height)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()

        let color: NSColor = lane == .zoom ? .systemPurple : .systemTeal
        let items: [(UUID, Double, Double, String)]
        switch lane {
        case .zoom:
            items = model.project.zooms.compactMap { z in
                outputRange(z).map { (z.id, $0.0, $0.1, String(format: "%.1f×", z.level) + (z.mode == .followCursor ? "  ⌖" : "")) }
            }
        case .camera:
            items = model.project.cameraFullscreen.compactMap { s in outputRange(s).map { (s.id, $0.0, $0.1, "Full Screen") } }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        for (id, a, b, text) in items {
            let r = segmentRect(start: a, end: b, lane: lane).insetBy(dx: 1, dy: 2)
            let selected = model.selection == (lane == .zoom ? .zoom(id) : .camera(id))
            let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            color.withAlphaComponent(selected ? 1 : 0.75).setFill()
            p.fill()
            if selected { NSColor.white.setStroke(); p.lineWidth = 2; p.stroke() }
            let s = text as NSString
            let size = s.size(withAttributes: attrs)
            if size.width + 10 < r.width {
                s.draw(at: NSPoint(x: r.minX + 8, y: r.midY - size.height / 2), withAttributes: attrs)
            }
        }
        // Hover ghost / hint on empty lane space.
        if let hx = hoverX, let hover = lastHoverPoint, l.contains(hover), !items.contains(where: { segmentRect(start: $0.1, end: $0.2, lane: lane).contains(hover) }) {
            let ghost = NSRect(x: hx, y: l.minY + 2, width: CGFloat(geometry.width(for: 2)), height: l.height - 4)
            let gp = NSBezierPath(roundedRect: ghost, xRadius: 6, yRadius: 6)
            color.withAlphaComponent(0.25).setFill(); gp.fill()
            let dash = gp; dash.setLineDash([4, 3], count: 2, phase: 0); dash.lineWidth = 1
            color.setStroke(); dash.stroke()
            let plus = "+" as NSString
            plus.draw(at: NSPoint(x: ghost.minX + 6, y: ghost.midY - 8), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: color])
        } else if items.isEmpty {
            let hint = (lane == .zoom ? "Click or drag to add zoom" : "Click or drag to show the camera full screen") as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
            let sz = hint.size(withAttributes: a)
            let vis = enclosingScrollView?.contentView.bounds ?? bounds
            hint.draw(at: NSPoint(x: vis.minX + 24, y: l.midY - sz.height / 2), withAttributes: a)
        }
    }

    // MARK: Hit testing

    private enum Hit {
        case ruler, empty
        case clip(UUID), clipLeft(UUID), clipRight(UUID)
        case segment(Lane, UUID), segLeft(Lane, UUID), segRight(Lane, UUID), lane(Lane)
    }

    private func hit(_ p: NSPoint) -> Hit {
        if p.y < rulerHeight + 4 { return .ruler }
        let (cy, ch) = clipRect
        if p.y >= cy && p.y <= cy + ch {
            let starts = model.timeline.outputStarts
            for (i, c) in model.project.clips.enumerated() {
                let x0 = CGFloat(geometry.x(for: starts[i])), x1 = CGFloat(geometry.x(for: starts[i] + c.duration))
                guard p.x >= x0 - 4 && p.x <= x1 + 4 else { continue }
                if abs(p.x - x0) <= 7 && x1 - x0 > 20 { return .clipLeft(c.id) }
                if abs(p.x - x1) <= 7 && x1 - x0 > 20 { return .clipRight(c.id) }
                if p.x >= x0 && p.x <= x1 { return .clip(c.id) }
            }
            return .empty
        }
        for lane in model.hasCamera ? [Lane.zoom, .camera] : [.zoom] where laneRect(lane).contains(p) {
            let segs: [(UUID, Double, Double)] = lane == .zoom
                ? model.project.zooms.compactMap { z in outputRange(z).map { (z.id, $0.0, $0.1) } }
                : model.project.cameraFullscreen.compactMap { s in outputRange(s).map { (s.id, $0.0, $0.1) } }
            for (id, a, b) in segs {
                let r = segmentRect(start: a, end: b, lane: lane)
                guard p.x >= r.minX - 4 && p.x <= r.maxX + 4 else { continue }
                if abs(p.x - r.minX) <= 6 && r.width > 16 { return .segLeft(lane, id) }
                if abs(p.x - r.maxX) <= 6 && r.width > 16 { return .segRight(lane, id) }
                if r.contains(p) { return .segment(lane, id) }
            }
            return .lane(lane)
        }
        return .empty
    }

    // MARK: Mouse

    private var lastHoverPoint: NSPoint?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverX = p.x >= CGFloat(geometry.x(for: 0)) && p.x <= CGFloat(geometry.x(for: model.duration)) ? p.x : nil
        lastHoverPoint = p
        switch hit(p) {
        case .clipLeft, .clipRight, .segLeft, .segRight: NSCursor.resizeLeftRight.set()
        default: NSCursor.arrow.set()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil; lastHoverPoint = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    private enum Drag {
        case scrub
        case trimLeft(UUID, origin: Double)
        case trimRight(UUID, origin: Double)
        case move(Lane, UUID, outStart: Double)
        case resizeLeft(Lane, UUID)
        case resizeRight(Lane, UUID)
        case create(Lane, startTime: Double)
        case clipClick(UUID)
    }
    private var drag: Drag?
    private var dragStartX: CGFloat = 0
    private var dragged = false

    private func time(at x: CGFloat) -> Double { min(max(0, geometry.time(for: Double(x))), model.duration) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStartX = p.x
        dragged = false
        dragCounter += 1
        model.endCoalescing()
        switch hit(p) {
        case .ruler, .empty:
            drag = .scrub
            player?.isScrubbing = true
            player?.pause()
            player?.seek(toOutput: time(at: p.x))
        case .clip(let id):
            drag = .clipClick(id)
        case .clipLeft(let id):
            model.selection = .clip(id)
            drag = .trimLeft(id, origin: model.project.clips.first { $0.id == id }?.start ?? 0)
        case .clipRight(let id):
            model.selection = .clip(id)
            drag = .trimRight(id, origin: model.project.clips.first { $0.id == id }?.end ?? 0)
        case .segment(let lane, let id):
            model.selection = lane == .zoom ? .zoom(id) : .camera(id)
            let start = lane == .zoom ? model.project.zooms.first { $0.id == id }.flatMap { outputRange($0)?.0 }
                                      : model.project.cameraFullscreen.first { $0.id == id }.flatMap { outputRange($0)?.0 }
            drag = .move(lane, id, outStart: start ?? 0)
        case .segLeft(let lane, let id):
            model.selection = lane == .zoom ? .zoom(id) : .camera(id)
            drag = .resizeLeft(lane, id)
        case .segRight(let lane, let id):
            model.selection = lane == .zoom ? .zoom(id) : .camera(id)
            drag = .resizeRight(lane, id)
        case .lane(let lane):
            drag = .create(lane, startTime: time(at: p.x))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - dragStartX) > 3 { dragged = true }
        guard dragged || { if case .scrub = drag { return true }; return false }() else { return }
        let key = "timeline-drag-\(dragCounter)"
        let dt = Double(p.x - dragStartX) / geometry.pixelsPerSecond
        let tl = model.timeline
        let duration = model.project.recording.duration
        switch drag {
        case .scrub:
            player?.seek(toOutput: time(at: p.x))
        case .trimLeft(let id, let origin):
            model.update(coalesce: key) { p in var t = p.timeline; t.trimStart(id, to: origin + dt); p.clips = t.clips }
        case .trimRight(let id, let origin):
            model.update(coalesce: key) { p in var t = p.timeline; t.trimEnd(id, to: origin + dt); p.clips = t.clips }
        case .move(let lane, let id, let outStart):
            let src = tl.sourceTime(forOutput: max(0, outStart + dt))
            model.update(coalesce: key) { p in
                if lane == .zoom { LaneMath.move(id, toStart: src, in: &p.zooms, duration: duration) }
                else { LaneMath.move(id, toStart: src, in: &p.cameraFullscreen, duration: duration) }
            }
        case .resizeLeft(let lane, let id):
            let src = tl.sourceTime(forOutput: time(at: p.x))
            model.update(coalesce: key) { p in
                if lane == .zoom { LaneMath.resizeStart(id, to: src, in: &p.zooms) } else { LaneMath.resizeStart(id, to: src, in: &p.cameraFullscreen) }
            }
        case .resizeRight(let lane, let id):
            let src = tl.sourceTime(forOutput: time(at: p.x))
            model.update(coalesce: key) { p in
                if lane == .zoom { LaneMath.resizeEnd(id, to: src, in: &p.zooms, duration: duration) }
                else { LaneMath.resizeEnd(id, to: src, in: &p.cameraFullscreen, duration: duration) }
            }
        case .create:
            hoverX = p.x; lastHoverPoint = p
            needsDisplay = true
        case .clipClick, .none:
            break
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .scrub:
            player?.isScrubbing = false
        case .clipClick(let id):
            if !dragged {
                model.selection = .clip(id)
                player?.pause()
                player?.seek(toOutput: time(at: p.x))
            }
        case .create(let lane, let start):
            let end = time(at: p.x)
            let (a, b) = dragged ? (min(start, end), max(start, end)) : (start, min(model.duration, start + 2))
            if lane == .zoom { model.addZoom(outputStart: a, outputEnd: max(b, a + LaneMath.minimumDuration)) }
            else { model.addCameraSegment(outputStart: a, outputEnd: max(b, a + LaneMath.minimumDuration)) }
        default:
            break
        }
        drag = nil
        model.endCoalescing()
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            menu.addItem(i)
        }
        switch hit(p) {
        case .clip(let id), .clipLeft(let id), .clipRight(let id):
            model.selection = .clip(id)
            item("Split Clip at Playhead") { [weak self] in self?.model.splitClipAtPlayhead() }
            item("Delete Clip") { [weak self] in self?.model.deleteClip(id) }
        case .segment(.zoom, let id), .segLeft(.zoom, let id), .segRight(.zoom, let id):
            model.selection = .zoom(id)
            item("Split Zoom at Playhead") { [weak self] in self?.model.splitZoomAtPlayhead() }
            item("Apply Zoom Level to All") { [weak self] in self?.model.applyZoomLevelToAll() }
            menu.addItem(.separator())
            item("Delete Zoom") { [weak self] in self?.model.deleteSelection() }
            item("Remove All Zooms") { [weak self] in self?.model.removeAllZooms() }
        case .lane(.zoom):
            let t = time(at: p.x)
            item("Add Zoom Here") { [weak self] in self?.model.addZoom(outputStart: t, outputEnd: t + 2) }
            if !model.project.zooms.isEmpty { item("Remove All Zooms") { [weak self] in self?.model.removeAllZooms() } }
        case .segment(.camera, let id), .segLeft(.camera, let id), .segRight(.camera, let id):
            model.selection = .camera(id)
            item("Delete Full Screen Segment") { [weak self] in self?.model.deleteSelection() }
        default:
            return nil
        }
        return menu
    }
}

/// Playhead line + knob, a separate layer so playback doesn't redraw the whole timeline.
final class PlayheadView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSRect(x: bounds.midX - 1, y: 6, width: 2, height: bounds.height - 6).fill()
        let knob = NSBezierPath()
        knob.move(to: NSPoint(x: bounds.midX - 6, y: 2))
        knob.line(to: NSPoint(x: bounds.midX + 6, y: 2))
        knob.line(to: NSPoint(x: bounds.midX + 6, y: 12))
        knob.line(to: NSPoint(x: bounds.midX, y: 18))
        knob.line(to: NSPoint(x: bounds.midX - 6, y: 12))
        knob.close()
        knob.fill()
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, keyEquivalent: String = "", action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
