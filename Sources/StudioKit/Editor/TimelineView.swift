import AppKit
import AVFoundation
import Combine
import SuperScreenshotCore

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


/// The timeline (FLTimeline): ruler, zoom track, clip track with thumbnails, cut marks, camera full-screen track,
/// playhead. x positions are output-timeline seconds; zoom/camera segments live in source time and are mapped
/// through the clips.
@MainActor
final class TimelineView: NSView {
    enum Lane { case zoom, camera }

    private let model: EditorModel
    private weak var player: PlayerController?
    var thumbnails: ThumbnailProvider?
    private(set) var geometry = TimelineGeometry(pixelsPerSecond: 60)
    /// Called whenever the scale (points per second) changes, e.g. to sync the zoom slider.
    var onScaleChange: ((Double) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private let playheadView = PlayheadView()
    private var hoverX: CGFloat?
    private var lastHoverPoint: NSPoint?
    private var dragCounter = 0

    // Layout (flipped, top-left origin).
    static let rulerHeight: CGFloat = 24
    private static let zoomLane = (y: CGFloat(30), h: CGFloat(28))
    private static let clipLane = (y: CGFloat(64), h: CGFloat(56))
    private static let cutRow = (y: CGFloat(122), h: CGFloat(16))
    private static let cameraLane = (y: CGFloat(142), h: CGFloat(24))
    var contentHeight: CGFloat { model.hasCamera ? 174 : 146 }

    private static let scissorsCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [.white]))
        guard let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cut")?.withSymbolConfiguration(config) else { return .crosshair }
        return NSCursor(image: img, hotSpot: NSPoint(x: img.size.width / 2, y: img.size.height / 2))
    }()

    init(model: EditorModel, player: PlayerController) {
        self.model = model
        self.player = player
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 174))
        wantsLayer = true
        addSubview(playheadView)
        model.$project.receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.contentChanged() } }.store(in: &cancellables)
        model.$selection.receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } }.store(in: &cancellables)
        model.$tool.receive(on: DispatchQueue.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } }.store(in: &cancellables)
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
        onScaleChange?(geometry.pixelsPerSecond)
    }

    /// Multiplies the scale keeping the time under `anchorX` (document coords) in place; nil anchors on the playhead.
    func zoom(by factor: Double, anchorX: CGFloat? = nil) {
        setScale(geometry.pixelsPerSecond * factor, anchorX: anchorX)
    }

    func setScale(_ pixelsPerSecond: Double, anchorX: CGFloat? = nil) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let anchor = anchorX ?? CGFloat(geometry.x(for: model.playhead))
        let anchorTime = geometry.time(for: Double(anchor))
        let screenOffset = anchor - clip.bounds.origin.x
        geometry.pixelsPerSecond = TimelineGeometry.clampScale(pixelsPerSecond)
        updateWidth()
        let newX = CGFloat(geometry.x(for: anchorTime)) - screenOffset
        clip.scroll(to: NSPoint(x: min(max(0, newX), max(0, frame.width - clip.bounds.width)), y: 0))
        enclosingScrollView?.reflectScrolledClipView(clip)
        needsDisplay = true
        playheadMoved()
        onScaleChange?(geometry.pixelsPerSecond)
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
        let r = lane == .zoom ? Self.zoomLane : Self.cameraLane
        return NSRect(x: 0, y: r.y, width: bounds.width, height: r.h)
    }

    private func segmentRect(start: Double, end: Double, lane: Lane) -> NSRect {
        let l = laneRect(lane)
        let x0 = CGFloat(geometry.x(for: start)), x1 = CGFloat(geometry.x(for: end))
        return NSRect(x: x0, y: l.minY, width: max(2, x1 - x0), height: l.height)
    }

    private func segments(_ lane: Lane) -> [(id: UUID, start: Double, end: Double, title: String)] {
        switch lane {
        case .zoom:
            return model.project.zooms.compactMap { z in outputRange(z).map { (z.id, $0.0, $0.1, "Zoom \(percent(z.level))") } }
        case .camera:
            return model.project.cameraFullscreen.compactMap { s in outputRange(s).map { (s.id, $0.0, $0.1, "Camera Full Screen") } }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        StudioTheme.window.setFill()
        dirtyRect.fill()
        drawRuler(dirtyRect)
        drawLane(.zoom)
        drawClips(dirtyRect)
        drawCuts()
        if model.hasCamera { drawLane(.camera) }
        if let hx = hoverX {
            if model.tool == .cut, let p = lastHoverPoint, p.y >= Self.clipLane.y, p.y <= Self.clipLane.y + Self.clipLane.h {
                NSColor.white.setFill()
                NSRect(x: hx - 0.75, y: Self.clipLane.y - 2, width: 1.5, height: Self.clipLane.h + 4).fill()
            } else {
                NSColor.white.withAlphaComponent(0.35).setFill()
                NSRect(x: hx - 0.5, y: Self.rulerHeight, width: 1, height: bounds.height - Self.rulerHeight).fill()
            }
        }
        thumbnails?.flush()
    }

    private func drawRuler(_ dirty: NSRect) {
        let step = geometry.rulerStep
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        let t0 = max(0, (geometry.time(for: Double(dirty.minX) - 60) / step).rounded(.down) * step)
        let t1 = min(model.duration, geometry.time(for: Double(dirty.maxX) + 60))
        var t = t0
        while t <= t1 + 1e-9 {
            let x = CGFloat(geometry.x(for: t)).rounded() + 0.5
            NSColor.white.withAlphaComponent(0.05).setFill()
            NSRect(x: x - 0.5, y: Self.rulerHeight - 6, width: 1, height: bounds.height - Self.rulerHeight + 6).fill()
            let label = step < 1 ? TimeFormat.string(t) : TimeFormat.clock(t)
            (label as NSString).draw(at: NSPoint(x: x + 4, y: 4), withAttributes: attrs)
            t += step
        }
    }

    private func drawClips(_ dirty: NSRect) {
        let starts = model.timeline.outputStarts
        let (y, h) = Self.clipLane
        for (i, clip) in model.project.clips.enumerated() {
            let x0 = CGFloat(geometry.x(for: starts[i])), w = CGFloat(geometry.width(for: clip.duration))
            let r = NSRect(x: x0 + 2, y: y, width: max(2, w - 4), height: h)
            guard r.intersects(dirty) else { continue }
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            StudioTheme.track.setFill()
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
            let border = NSBezierPath(roundedRect: r.insetBy(dx: selected ? 1 : 0.5, dy: selected ? 1 : 0.5), xRadius: 8, yRadius: 8)
            border.lineWidth = selected ? 2 : 1
            (selected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.1)).setStroke()
            border.stroke()
            // Trim handles.
            if model.tool == .selection, selected || (hoverX.map { $0 >= r.minX && $0 <= r.maxX } ?? false) {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX + 3, y: r.midY - 10, width: 3, height: 20), xRadius: 1.5, yRadius: 1.5).fill()
                NSBezierPath(roundedRect: NSRect(x: r.maxX - 6, y: r.midY - 10, width: 3, height: 20), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    /// Grey scissors badges under the clip track at every cut; a removed range shows "✂ 4s".
    private func drawCuts() {
        let clips = model.project.clips
        guard !clips.isEmpty else { return }
        let starts = model.timeline.outputStarts
        var cuts: [(x: Double, removed: Double)] = []
        if clips[0].start > 0.01 { cuts.append((starts[0], clips[0].start)) }
        for i in 1..<clips.count { cuts.append((starts[i], max(0, clips[i].start - clips[i - 1].end))) }
        if let last = clips.last, model.project.recording.duration - last.end > 0.01 {
            cuts.append((model.duration, model.project.recording.duration - last.end))
        }
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.white]))
        let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Cut")?.withSymbolConfiguration(config)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
        let (y, h) = Self.cutRow
        for cut in cuts {
            let x = CGFloat(geometry.x(for: cut.x))
            let text = cut.removed >= 0.5 ? "\(Int(cut.removed.rounded()))s" as NSString : nil
            let textW = text.map { $0.size(withAttributes: attrs).width + 4 } ?? 0
            let badge = NSRect(x: x - (h + textW) / 2, y: y, width: h + textW, height: h)
            NSColor(white: 0.32, alpha: 1).setFill()
            NSBezierPath(roundedRect: badge, xRadius: h / 2, yRadius: h / 2).fill()
            scissors?.draw(in: NSRect(x: badge.minX + 3, y: y + 3, width: h - 6, height: h - 6))
            text?.draw(at: NSPoint(x: badge.minX + h - 1, y: y + 1), withAttributes: attrs)
        }
    }

    private func drawLane(_ lane: Lane) {
        let l = laneRect(lane)
        let track = NSRect(x: CGFloat(geometry.x(for: 0)), y: l.minY, width: CGFloat(geometry.width(for: model.duration)), height: l.height)
        StudioTheme.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()

        let items = segments(lane)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        for item in items {
            let r = segmentRect(start: item.start, end: item.end, lane: lane).insetBy(dx: 1, dy: 2)
            let selected = model.selection == (lane == .zoom ? .zoom(item.id) : .camera(item.id))
            (selected ? NSColor.controlAccentColor : StudioTheme.segment).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            let s = item.title as NSString
            let size = s.size(withAttributes: attrs)
            if size.width + 12 < r.width {
                s.draw(at: NSPoint(x: r.minX + 8, y: r.midY - size.height / 2), withAttributes: attrs)
            }
        }
        // Hover ghost on empty lane space, or the hint when the lane is empty.
        if model.tool == .selection, let hx = hoverX, let hover = lastHoverPoint, l.contains(hover),
           !items.contains(where: { segmentRect(start: $0.start, end: $0.end, lane: lane).contains(hover) }) {
            let ghost = NSRect(x: hx, y: l.minY + 2, width: CGFloat(geometry.width(for: 2)), height: l.height - 4)
            let gp = NSBezierPath(roundedRect: ghost, xRadius: 6, yRadius: 6)
            StudioTheme.segment.withAlphaComponent(0.5).setFill(); gp.fill()
            ("+" as NSString).draw(at: NSPoint(x: ghost.minX + 7, y: ghost.midY - 8),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        } else if items.isEmpty {
            let hint = (lane == .zoom ? "+  Click or drag to add zoom" : "+  Click or drag to show the camera full screen") as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
            let sz = hint.size(withAttributes: a)
            let vis = enclosingScrollView?.contentView.bounds ?? bounds
            hint.draw(at: NSPoint(x: max(track.minX, vis.minX) + 10, y: l.midY - sz.height / 2), withAttributes: a)
        }
    }

    // MARK: Hit testing

    private enum Hit {
        case ruler, empty
        case clip(UUID), clipLeft(UUID), clipRight(UUID)
        case segment(Lane, UUID), segLeft(Lane, UUID), segRight(Lane, UUID), lane(Lane)
    }

    private func hit(_ p: NSPoint) -> Hit {
        if p.y < Self.rulerHeight + 2 { return .ruler }
        let (cy, ch) = Self.clipLane
        if p.y >= cy && p.y <= cy + ch {
            let starts = model.timeline.outputStarts
            for (i, c) in model.project.clips.enumerated() {
                let x0 = CGFloat(geometry.x(for: starts[i])), x1 = CGFloat(geometry.x(for: starts[i] + c.duration))
                guard p.x >= x0 - 4 && p.x <= x1 + 4 else { continue }
                if model.tool == .selection {
                    if abs(p.x - x0) <= 7 && x1 - x0 > 20 { return .clipLeft(c.id) }
                    if abs(p.x - x1) <= 7 && x1 - x0 > 20 { return .clipRight(c.id) }
                }
                if p.x >= x0 && p.x <= x1 { return .clip(c.id) }
            }
            return .empty
        }
        for lane in model.hasCamera ? [Lane.zoom, .camera] : [.zoom] where laneRect(lane).contains(p) {
            for seg in segments(lane) {
                let r = segmentRect(start: seg.start, end: seg.end, lane: lane)
                guard p.x >= r.minX - 4 && p.x <= r.maxX + 4 else { continue }
                if abs(p.x - r.minX) <= 6 && r.width > 16 { return .segLeft(lane, seg.id) }
                if abs(p.x - r.maxX) <= 6 && r.width > 16 { return .segRight(lane, seg.id) }
                if r.contains(p) { return .segment(lane, seg.id) }
            }
            return .lane(lane)
        }
        return .empty
    }

    // MARK: Mouse

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
        updateCursor(at: p)
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    private func updateCursor(at p: NSPoint) {
        switch hit(p) {
        case .clip where model.tool == .cut: Self.scissorsCursor.set()
        case .clipLeft, .clipRight, .segLeft, .segRight: NSCursor.resizeLeftRight.set()
        default: NSCursor.arrow.set()
        }
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
            if model.tool == .cut {
                model.splitClip(atOutput: time(at: p.x))
                drag = nil
            } else {
                drag = .clipClick(id)
            }
        case .clipLeft(let id):
            model.selection = .clip(id)
            drag = .trimLeft(id, origin: model.project.clips.first { $0.id == id }?.start ?? 0)
        case .clipRight(let id):
            model.selection = .clip(id)
            drag = .trimRight(id, origin: model.project.clips.first { $0.id == id }?.end ?? 0)
        case .segment(let lane, let id):
            model.selection = lane == .zoom ? .zoom(id) : .camera(id)
            drag = .move(lane, id, outStart: segments(lane).first { $0.id == id }?.start ?? 0)
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
        func item(_ title: String, in m: NSMenu? = nil, on: Bool = false, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            i.state = on ? .on : .off
            (m ?? menu).addItem(i)
        }
        switch hit(p) {
        case .clip(let id), .clipLeft(let id), .clipRight(let id):
            model.selection = .clip(id)
            let t = time(at: p.x)
            item("Split Clip Here") { [weak self] in self?.model.splitClip(atOutput: t) }
            item("Split Clip at Playhead") { [weak self] in self?.model.splitClipAtPlayhead() }
            menu.addItem(.separator())
            item("Delete Clip") { [weak self] in self?.model.deleteClip(id) }
        case .segment(.zoom, let id), .segLeft(.zoom, let id), .segRight(.zoom, let id):
            model.selection = .zoom(id)
            guard let z = model.project.zooms.first(where: { $0.id == id }) else { return nil }
            let levels = NSMenu()
            for level in [1.25, 1.5, 1.75, 2, 2.5, 3, 4] {
                item(percent(level), in: levels, on: abs(z.level - level) < 0.001) { [weak self] in self?.model.setZoom(id, level: level) }
            }
            let levelItem = NSMenuItem(title: "Zoom Level", action: nil, keyEquivalent: ""); levelItem.submenu = levels
            menu.addItem(levelItem)
            item("Apply Zoom Level to All") { [weak self] in self?.model.applyZoomLevelToAll() }
            let modes = NSMenu()
            for mode in [ZoomMode.followCursor, .manual] {
                item(mode.title, in: modes, on: z.mode == mode) { [weak self] in self?.model.setZoom(id, mode: mode) }
            }
            let modeItem = NSMenuItem(title: "Zoom Mode", action: nil, keyEquivalent: ""); modeItem.submenu = modes
            if model.events.cursor.isEmpty { modeItem.isEnabled = false }
            menu.addItem(modeItem)
            menu.addItem(.separator())
            item("Split Zoom at Playhead") { [weak self] in self?.model.splitZoomAtPlayhead() }
            item("Duplicate") { [weak self] in self?.model.duplicateZoom(id) }
            item("Remove") { [weak self] in self?.model.deleteSelection() }
            menu.addItem(.separator())
            item("Remove All Zooms") { [weak self] in self?.model.removeAllZooms() }
        case .lane(.zoom):
            let t = time(at: p.x)
            item("Add Zoom Here") { [weak self] in self?.model.addZoom(outputStart: t, outputEnd: t + 2) }
            if !model.project.zooms.isEmpty { item("Remove All Zooms") { [weak self] in self?.model.removeAllZooms() } }
        case .segment(.camera, let id), .segLeft(.camera, let id), .segRight(.camera, let id):
            model.selection = .camera(id)
            item("Remove Full Screen Segment") { [weak self] in self?.model.deleteSelection() }
        default:
            return nil
        }
        return menu
    }
}

/// Playhead: 1 pt red line with a rounded red pin head above the ruler. A separate view so playback doesn't
/// redraw the whole timeline.
final class PlayheadView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSRect(x: bounds.midX - 0.5, y: 8, width: 1, height: bounds.height - 8).fill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 4.5, y: 0, width: 9, height: 13), xRadius: 4.5, yRadius: 4.5).fill()
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
