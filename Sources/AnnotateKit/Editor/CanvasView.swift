import AppKit
import UniformTypeIdentifiers
import ShotcraftCore

/// The editing surface. It is the document view of a magnifying `NSScrollView`, so its own coordinates are
/// unzoomed: view point = document point + `docOffset`. Drawing goes through `AnnotateRenderer` (same code as
/// export); selection handles, guides, marquee and the crop overlay are drawn on top.
@MainActor
final class CanvasView: NSView, NSTextViewDelegate {
    static let margin: CGFloat = 40

    let session: EditorSession
    /// Called when the working crop rect changes (crop bar fields).
    var onCropChange: ((CGRect) -> Void)?
    /// Files dropped onto the canvas (document point of the drop).
    var onDropFiles: (([URL], CGPoint) -> Void)?
    /// Asks the controller to open the context menu for the current selection.
    var contextMenuProvider: (() -> NSMenu?)?
    /// Single-key shortcuts owned by the window (e.g. `g` toggles the background tool). Return true if handled.
    var extraKeyHandler: ((Character) -> Bool)?

    private(set) var layout: CompositionLayout
    private var docOffset = CGVector(dx: margin, dy: margin)

    // Interaction
    private enum Drag {
        case none
        case creating(anchor: CGPoint)
        case freehand
        case moving(start: CGPoint, originals: [Annotation])
        case handle(id: UUID, handle: Annotation.Handle, original: Annotation)
        case marquee(start: CGPoint, current: CGPoint, base: Set<UUID>)
        case panning(startInWindow: CGPoint, startOrigin: CGPoint)
        case cropMove(start: CGPoint, original: CGRect)
        case cropHandle(Geo.RectHandle, original: CGRect)
        case cropNew(anchor: CGPoint)
    }
    private var drag: Drag = .none
    private var newObject: Annotation?
    private var lastDragPoint: CGPoint = .zero
    private var guides: [Snapping.Guide] = []
    private var spaceDown = false

    // Inline text editing
    private var textView: InlineTextView?
    private(set) var editingID: UUID?

    // Crop
    private(set) var isCropping = false
    private(set) var cropWorking: CGRect = .zero
    /// Locked aspect ratio (w/h) for the crop, nil = freeform.
    var cropAspect: CGFloat? { didSet { if let r = cropAspect, isCropping { setCrop(Geo.fit(ratio: r, in: cropWorking)) } } }
    private var toolBeforeCrop: AnnotateTool = .arrow

    init(session: EditorSession) {
        self.session = session
        self.layout = session.exportLayout()
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        session.observe { [weak self] change in self?.sessionChanged(change) }
        relayout()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var tolerance: CGFloat { 5 / magnification }
    private var handleRadius: CGFloat { 5 / magnification }

    // MARK: Coordinates

    func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + docOffset.dx, y: p.y + docOffset.dy) }
    func viewRect(_ r: CGRect) -> CGRect { r.offsetBy(dx: docOffset.dx, dy: docOffset.dy) }
    func docPoint(_ v: CGPoint) -> CGPoint { CGPoint(x: v.x - docOffset.dx, y: v.y - docOffset.dy) }
    private func docPoint(_ e: NSEvent) -> CGPoint { docPoint(convert(e.locationInWindow, from: nil)) }

    /// Visible document rect (for "Add image" placement, zoom anchoring).
    var visibleDocRect: CGRect {
        let v = visibleRect
        return CGRect(origin: docPoint(v.origin), size: v.size)
    }

    // MARK: Layout

    private var displayState: CanvasState {
        guard isCropping else { return session.state }
        var s = session.state
        s.cropRect = nil
        s.background = BackgroundSettings()
        return s
    }

    /// Recomputes the composition layout and resizes the view, keeping the image stationary on screen.
    func relayout() {
        let s = session.state
        if isCropping {
            var u = displayState
            u.cropRect = nil
            let bounds = u.contentBounds(expand: session.expandCanvas).union(cropWorking)
            layout = CompositionLayout.make(contentBounds: Geo.pixelAligned(bounds, scale: s.scale), background: BackgroundSettings(), scale: s.scale)
        } else {
            layout = session.exportLayout()
        }
        let m = Self.margin
        let newOffset = CGVector(dx: m + layout.documentToOutput.dx, dy: m + layout.documentToOutput.dy)
        let delta = CGVector(dx: newOffset.dx - docOffset.dx, dy: newOffset.dy - docOffset.dy)
        docOffset = newOffset
        let size = CGSize(width: ceil(layout.outputSize.width + m * 2), height: ceil(layout.outputSize.height + m * 2))
        if frame.size != size { setFrameSize(size) }
        if (delta.dx != 0 || delta.dy != 0), let clip = enclosingScrollView?.contentView {
            var o = clip.bounds.origin
            o.x += delta.dx; o.y += delta.dy
            clip.scroll(to: o)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        if let tv = textView, let id = editingID, let a = session.object(id) { tv.frame = textViewFrame(a) }
        needsDisplay = true
    }

    /// Inline editor frame: the object's frame plus a little slack so TextKit never clips the last line.
    private func textViewFrame(_ a: Annotation) -> CGRect {
        var r = viewRect(a.frame)
        r.size.height += 4
        r.size.width += 2
        return r
    }

    private func sessionChanged(_ change: EditorSession.Change) {
        switch change {
        case .content:
            if !session.isInteracting && newObject == nil { relayout() } else { needsDisplay = true }
        case .selection, .style:
            needsDisplay = true
        case .tool:
            if editingID != nil { endTextEditing() }
            if session.tool == .crop && !isCropping { enterCrop() }
            else if session.tool != .crop && isCropping { exitCrop() }
            if session.tool != .select && session.tool != .crop {
                // Keep a selection only if it matches the new tool (so its handles stay useful).
                let kind = session.tool.kind
                session.selection = session.selection.filter { session.object($0)?.kind == kind }
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    // MARK: Drawing

    private static let checkerColor: NSColor = {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            NSColor(white: 1, alpha: 1).setFill(); r.fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: img)
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = displayState
        let m = Self.margin
        let outputRect = CGRect(x: m, y: m, width: layout.outputSize.width, height: layout.outputSize.height)

        // Checkerboard behind transparency (never exported).
        if !s.background.isActive {
            Self.checkerColor.setFill()
            outputRect.fill()
        }

        ctx.saveGState()
        ctx.translateBy(x: m, y: m)
        ctx.interpolationQuality = magnification >= 2 ? .none : .high
        var opts = AnnotateRenderer.Options()
        opts.hiddenObjectID = editingID
        opts.extraObject = newObject
        opts.clipToContent = !(isDrawingSomething && session.expandCanvas && !isCropping)
        session.renderer.draw(s, layout: layout, in: ctx, options: opts)
        ctx.restoreGState()

        if isCropping { drawCropOverlay(ctx); return }
        drawSelection(ctx)
        drawGuides(ctx)
        if case let .marquee(start, current, _) = drag {
            let r = viewRect(Geo.rect(start, current))
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            r.fill()
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1 / magnification
            p.stroke()
        }
    }

    private var isDrawingSomething: Bool {
        switch drag {
        case .none, .marquee, .panning: return false
        default: return true
        }
    }

    private func drawSelection(_ ctx: CGContext) {
        let selected = session.selectedObjects.filter { $0.id != editingID }
        guard !selected.isEmpty else { return }
        let lw = 1 / magnification
        let accent = NSColor.controlAccentColor
        for a in selected where !a.kind.isLineBased {
            let r = viewRect(a.frame).insetBy(dx: -2 / magnification, dy: -2 / magnification)
            let p = NSBezierPath(rect: r)
            p.lineWidth = lw
            p.setLineDash([4 / magnification, 3 / magnification], count: 2, phase: 0)
            accent.setStroke()
            p.stroke()
        }
        if selected.count == 1, let a = selected.first {
            if a.kind == .arrow, a.arrowStyle == .curved {
                // Thin guide from the endpoints to the control point.
                let c = viewPoint(a.control ?? Geo.mid(a.start, a.end))
                let g = NSBezierPath()
                g.move(to: viewPoint(a.start)); g.line(to: c); g.line(to: viewPoint(a.end))
                g.lineWidth = lw
                g.setLineDash([3 / magnification, 3 / magnification], count: 2, phase: 0)
                accent.withAlphaComponent(0.6).setStroke()
                g.stroke()
            }
            for (h, pt) in a.handles {
                let v = viewPoint(pt)
                let r = handleRadius
                let circle = NSBezierPath(ovalIn: CGRect(x: v.x - r, y: v.y - r, width: r * 2, height: r * 2))
                (h == .control ? accent : NSColor.white).setFill()
                circle.fill()
                circle.lineWidth = 1.5 / magnification
                (h == .control ? NSColor.white : accent).setStroke()
                circle.stroke()
            }
        }
    }

    private func drawGuides(_ ctx: CGContext) {
        guard !guides.isEmpty else { return }
        let b = viewRect(layout.contentBounds).insetBy(dx: -2000, dy: -2000)
        for g in guides {
            let p = NSBezierPath()
            if g.axis == .vertical {
                let x = g.position + docOffset.dx
                p.move(to: CGPoint(x: x, y: b.minY)); p.line(to: CGPoint(x: x, y: b.maxY))
            } else {
                let y = g.position + docOffset.dy
                p.move(to: CGPoint(x: b.minX, y: y)); p.line(to: CGPoint(x: b.maxX, y: y))
            }
            p.lineWidth = 1 / magnification
            (g.isCanvas ? NSColor.systemRed : NSColor.systemBlue).setStroke()
            p.stroke()
        }
    }

    private func drawCropOverlay(_ ctx: CGContext) {
        let crop = viewRect(cropWorking)
        let all = bounds
        let dim = NSBezierPath(rect: all)
        dim.append(NSBezierPath(rect: crop).reversed)
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()

        let lw = 1 / magnification
        // Rule-of-thirds grid.
        let grid = NSBezierPath()
        for i in 1...2 {
            let x = crop.minX + crop.width * CGFloat(i) / 3, y = crop.minY + crop.height * CGFloat(i) / 3
            grid.move(to: CGPoint(x: x, y: crop.minY)); grid.line(to: CGPoint(x: x, y: crop.maxY))
            grid.move(to: CGPoint(x: crop.minX, y: y)); grid.line(to: CGPoint(x: crop.maxX, y: y))
        }
        grid.lineWidth = lw
        NSColor.white.withAlphaComponent(0.35).setStroke()
        grid.stroke()
        let border = NSBezierPath(rect: crop)
        border.lineWidth = 1.5 / magnification
        NSColor.white.setStroke()
        border.stroke()
        // Corner + edge handles.
        let hl = 14 / magnification, ht = 4 / magnification
        NSColor.white.setFill()
        for h in Geo.RectHandle.allCases {
            let p = h.point(in: crop)
            if h.isCorner {
                // An "L" pointing into the crop rect.
                let sx: CGFloat = h.movesMinX ? 1 : -1, sy: CGFloat = h.movesMinY ? 1 : -1
                NSRect(x: min(p.x, p.x + sx * hl), y: p.y - ht / 2, width: hl, height: ht).fill()
                NSRect(x: p.x - ht / 2, y: min(p.y, p.y + sy * hl), width: ht, height: hl).fill()
            } else {
                let horizontal = h == .top || h == .bottom
                NSRect(x: p.x - (horizontal ? hl / 2 : ht / 2), y: p.y - (horizontal ? ht / 2 : hl / 2),
                       width: horizontal ? hl : ht, height: horizontal ? ht : hl).fill()
            }
        }
        // Size badge.
        let px = CGSize(width: (cropWorking.width * session.state.scale).rounded(), height: (cropWorking.height * session.state.scale).rounded())
        let label = "\(Int(px.width)) × \(Int(px.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 / magnification, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let pad = 4 / magnification
        var badge = CGRect(x: crop.midX - size.width / 2 - pad * 2, y: crop.maxY + 6 / magnification,
                           width: size.width + pad * 4, height: size.height + pad * 2)
        if badge.maxY > visibleRect.maxY { badge.origin.y = crop.maxY - badge.height - 6 / magnification }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        label.draw(at: CGPoint(x: badge.minX + pad * 2, y: badge.minY + pad), withAttributes: attrs)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        switch session.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: spaceDown ? .openHand : cursor)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if editingID != nil {
            endTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let p = docPoint(event)
        lastDragPoint = p
        let flags = event.modifierFlags
        if spaceDown {
            beginPan(event); return
        }
        if isCropping { cropMouseDown(p); return }

        // 1. Handles of the single selected object.
        if session.selection.count == 1, let id = session.selection.first, let a = session.object(id),
           let h = a.handles.first(where: { Geo.dist($0.1, p) <= handleRadius + 3 / magnification })?.0 {
            session.beginInteraction()
            drag = .handle(id: id, handle: h, original: a)
            return
        }

        // 2. Double-click on text edits it.
        if event.clickCount == 2, let hit = session.hitObject(at: p, tolerance: tolerance, where: { $0.kind == .text }) {
            beginTextEditing(hit.id, startState: nil)
            return
        }

        // 3. Existing objects. Drawing tools only grab objects of their own kind (or the current selection),
        //    so you can start an arrow on top of a pixelated area.
        let tool = session.tool
        let hit = session.hitObject(at: p, tolerance: tolerance) { a in
            tool == .select || a.kind == tool.kind || self.session.selection.contains(a.id)
        }
        if let hit {
            if flags.contains(.shift) {
                if session.selection.contains(hit.id) { session.selection.remove(hit.id) } else { session.selection.insert(hit.id) }
                return
            }
            if !session.selection.contains(hit.id) { session.selection = [hit.id] }
            if flags.contains(.option) {
                // ⌥-drag duplicates.
                let copies = session.selectedObjects
                session.insert(copies, offset: .zero)
            }
            session.beginInteraction()
            drag = .moving(start: p, originals: session.selectedObjects)
            return
        }

        // 4. Empty space.
        switch tool {
        case .select:
            let base = flags.contains(.shift) ? session.selection : []
            session.selection = base
            drag = .marquee(start: p, current: p, base: base)
        case .text:
            session.selection = []
            createText(at: p)
        case .counter:
            guard let a = session.makeObject(for: .counter, at: p) else { return }
            session.apply { $0.objects.append(a) }
            session.selection = [a.id]
        case .crop:
            break
        default:
            session.selection = []
            guard var a = session.makeObject(for: tool, at: p) else { return }
            if a.kind == .arrow && a.arrowStyle == .curved { a.control = p }
            newObject = a
            drag = (a.kind == .pen || (a.kind == .highlighter && a.highlightShape == .freehand)) ? .freehand : .creating(anchor: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = docPoint(event)
        lastDragPoint = p
        update(at: p, flags: event.modifierFlags, event: event)
        if case .panning = drag {} else { autoscroll(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        switch drag {
        case .creating, .handle, .cropHandle, .cropNew: update(at: lastDragPoint, flags: event.modifierFlags, event: nil)
        default: break
        }
    }

    private func update(at p: CGPoint, flags: NSEvent.ModifierFlags, event: NSEvent?) {
        let shift = flags.contains(.shift), option = flags.contains(.option)
        switch drag {
        case .none:
            return
        case .creating(let anchor):
            guard var a = newObject else { return }
            if a.kind.isLineBased {
                var end = shift ? Geo.constrainAngle(p, from: anchor) : p
                var start = anchor
                if option { start = CGPoint(x: 2 * anchor.x - end.x, y: 2 * anchor.y - end.y) }
                if end == start { end.x += 0.01 }
                a.start = start; a.end = end
                if a.kind == .arrow && a.arrowStyle == .curved {
                    // Default bend: a gentle arc to one side, editable with the control handle.
                    let mid = Geo.mid(start, end)
                    let d = Geo.sub(end, start)
                    a.control = CGPoint(x: mid.x - d.dy * 0.2, y: mid.y + d.dx * 0.2)
                }
            } else {
                let (s, e) = Geo.dragRect(from: anchor, to: p, square: shift, fromCenter: option)
                a.start = s; a.end = e
            }
            newObject = a
        case .freehand:
            guard var a = newObject, let first = a.points.first else { return }
            if shift {
                a.points = [first, Geo.constrainAngle(p, from: first)]
            } else if let last = a.points.last, Geo.dist(last, p) >= 0.5 / magnification {
                a.points.append(p)
            }
            newObject = a
        case .moving(let start, let originals):
            var d = Geo.sub(p, start)
            if shift { if abs(d.dx) > abs(d.dy) { d.dy = 0 } else { d.dx = 0 } }
            let union = originals.reduce(CGRect.null) { $0.union($1.frame) }.offsetBy(dx: d.dx, dy: d.dy)
            if flags.contains(.command) {
                guides = []
            } else {
                let ids = Set(originals.map(\.id))
                let targets = session.state.objects.filter { !ids.contains($0.id) }.map(\.frame)
                let snap = Snapping.snap(union, targets: targets, canvas: session.state.imageRect, threshold: 5 / magnification)
                d.dx += snap.offset.dx; d.dy += snap.offset.dy
                guides = snap.guides
            }
            let moved = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.moved(by: d)) })
            session.update { s in s.objects = s.objects.map { moved[$0.id] ?? $0 } }
        case .handle(let id, let handle, let original):
            let updated = Annotation.dragging(original, handle: handle, to: p, shift: shift, option: option)
            session.update { s in
                if let i = s.objects.firstIndex(where: { $0.id == id }) { s.objects[i] = updated }
            }
        case .marquee(let start, _, let base):
            drag = .marquee(start: start, current: p, base: base)
            let r = Geo.rect(start, p)
            session.selection = base.union(session.state.objects.filter { $0.intersects(r) }.map(\.id))
        case .panning(let startInWindow, let startOrigin):
            guard let event, let clip = enclosingScrollView?.contentView else { return }
            let now = event.locationInWindow
            let mag = magnification
            // Window y is up, the (flipped) clip view's y is down.
            let o = CGPoint(x: startOrigin.x - (now.x - startInWindow.x) / mag, y: startOrigin.y + (now.y - startInWindow.y) / mag)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: o, size: clip.bounds.size)).origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        case .cropMove, .cropHandle, .cropNew:
            cropDragged(p, shift: shift, option: option, snap: !flags.contains(.command))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        guides = []
        switch finished {
        case .creating, .freehand:
            if var a = newObject, isMeaningful(a) {
                newObject = nil
                if a.kind == .pen || a.kind == .highlighter { a.points = PathSmoothing.thinned(a.points, minDistance: 0.75) }
                session.apply { $0.objects.append(a) }
                session.selection = [a.id]
            } else {
                newObject = nil
                relayout()
            }
        case .moving, .handle:
            session.endInteraction()
            relayout()
        case .panning:
            NSCursor.openHand.set()
        case .cropMove, .cropHandle, .cropNew:
            if cropWorking.width < 2 || cropWorking.height < 2 { setCrop(session.state.imageRect) }
            relayout()
        default:
            break
        }
        needsDisplay = true
    }

    private func isMeaningful(_ a: Annotation) -> Bool {
        let minSize = 3 / magnification
        switch a.kind {
        case .line, .arrow: return Geo.dist(a.start, a.end) >= minSize
        case .pen: return !a.points.isEmpty
        case .highlighter: return a.highlightShape == .freehand ? a.points.count > 1 : (a.frame.width >= minSize && a.frame.height >= minSize)
        default: return a.frame.width >= minSize && a.frame.height >= minSize
        }
    }

    override func otherMouseDown(with event: NSEvent) { beginPan(event) }
    override func otherMouseDragged(with event: NSEvent) { update(at: docPoint(event), flags: [], event: event) }
    override func otherMouseUp(with event: NSEvent) { drag = .none }

    private func beginPan(_ event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        drag = .panning(startInWindow: event.locationInWindow, startOrigin: clip.bounds.origin)
        NSCursor.closedHand.set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = docPoint(event)
        if let hit = session.hitObject(at: p, tolerance: tolerance), !session.selection.contains(hit.id) {
            session.selection = [hit.id]
        }
        return contextMenuProvider?()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch Int(event.keyCode) {
        case 49: // space
            if !event.isARepeat { spaceDown = true; NSCursor.openHand.set(); window?.invalidateCursorRects(for: self) }
            return
        case 51, 117: // delete, forward delete
            if !isCropping { session.deleteSelection() }
            return
        case 53: // escape
            if isCropping { cancelCrop(); return }
            if newObject != nil { newObject = nil; drag = .none; needsDisplay = true; return }
            if !session.selection.isEmpty { session.selection = [] } else if session.tool != .select { session.tool = .select }
            return
        case 36, 76: // return / enter
            if isCropping { applyCrop(); return }
            if session.selection.count == 1, let id = session.selection.first, session.object(id)?.kind == .text {
                beginTextEditing(id, startState: nil); return
            }
        case 123, 124, 125, 126: // arrows
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let d: CGVector
            switch Int(event.keyCode) {
            case 123: d = CGVector(dx: -step, dy: 0)
            case 124: d = CGVector(dx: step, dy: 0)
            case 125: d = CGVector(dx: 0, dy: step)
            default: d = CGVector(dx: 0, dy: -step)
            }
            if isCropping { setCrop(cropWorking.offsetBy(dx: d.dx, dy: d.dy)) } else { session.nudgeSelection(by: d) }
            return
        default:
            break
        }
        if flags.subtracting(.shift).isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased().first {
            if let t = AnnotateTool.forKey(ch) {
                if t == .crop { if !isCropping { startCrop() } } else { session.tool = t }
                return
            }
            if ch == "]" || ch == "[" { adjustThickness(ch == "]" ? 1 : -1); return }
            if extraKeyHandler?(ch) == true { return }
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            window?.invalidateCursorRects(for: self)
            NSCursor.arrow.set()
            return
        }
        super.keyUp(with: event)
    }

    /// `]` / `[`: thickness (or font size / counter size) of the current tool and selection.
    func adjustThickness(_ dir: Int) {
        func stepped(_ v: CGFloat, _ list: [CGFloat]) -> CGFloat {
            if dir > 0 { return list.first { $0 > v + 0.01 } ?? list.last! }
            return list.last { $0 < v - 0.01 } ?? list.first!
        }
        let tool = session.selection.isEmpty ? session.tool : (session.selectedObjects.first.map { AnnotateTool.forKind($0.kind) } ?? session.tool)
        switch tool {
        case .text:
            let v = stepped(session.style(for: .text).fontSize, ToolStyle.fontSizes)
            session.updateStyle(for: .text) { $0.fontSize = v }
            session.modifySelection(coalesce: "fontSize") { if $0.kind == .text { $0.fontSize = v } }
        case .counter:
            let v = stepped(session.style(for: .counter).counterSize, ToolStyle.counterSizes)
            session.updateStyle(for: .counter) { $0.counterSize = v }
            session.modifySelection(coalesce: "counterSize") { if $0.kind == .counter { $0.fontSize = v } }
        case .select, .crop, .pixelate, .spotlight:
            NSSound.beep()
        default:
            let v = stepped(session.style(for: tool).lineWidth, ToolStyle.widths)
            session.updateStyle(for: tool) { $0.lineWidth = v }
            session.modifySelection(coalesce: "lineWidth") { $0.lineWidth = v }
        }
    }

    // MARK: Text editing

    private func createText(at p: CGPoint) {
        let before = session.state
        guard var a = session.makeObject(for: .text, at: p) else { return }
        let pad = TextLayout.padding(a)
        a.start = CGPoint(x: p.x - pad, y: p.y - a.fontSize * 0.6 - pad)
        session.update { $0.objects.append(a) }
        session.selection = [a.id]
        beginTextEditing(a.id, startState: before)
    }

    /// Starts inline editing. `startState` is the state before a new text object was inserted, so creation
    /// and typing become one undo step.
    func beginTextEditing(_ id: UUID, startState: CanvasState?) {
        guard let a = session.object(id) else { return }
        if startState == nil { session.beginInteraction() } else { session.beginInteraction(from: startState!) }
        editingID = id
        session.selection = [id]
        let tv = InlineTextView(frame: textViewFrame(a))
        tv.configure(for: a)
        tv.delegate = self
        tv.onFinish = { [weak self] in self?.endTextEditing() }
        addSubview(tv)
        textView = tv
        window?.makeFirstResponder(tv)
        if !a.text.isEmpty { tv.selectAll(nil) }
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID else { return }
        let text = tv.string
        session.update { s in
            if let i = s.objects.firstIndex(where: { $0.id == id }) { s.objects[i].text = text }
        }
        if let a = session.object(id) { tv.frame = textViewFrame(a) }
    }

    func endTextEditing() {
        guard let tv = textView, let id = editingID else { return }
        textView = nil
        editingID = nil
        let text = tv.string
        tv.delegate = nil
        tv.removeFromSuperview()
        session.update { s in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                s.objects.removeAll { $0.id == id }
            } else if let i = s.objects.firstIndex(where: { $0.id == id }) {
                s.objects[i].text = text
            }
        }
        session.endInteraction()
        window?.makeFirstResponder(self)
        relayout()
    }

    /// Restyles the inline editor after a toolbar change while editing.
    func refreshTextEditor() {
        guard let tv = textView, let id = editingID, let a = session.object(id) else { return }
        tv.configure(for: a, keepText: true)
        tv.frame = textViewFrame(a)
    }

    // MARK: Crop

    private var uncroppedBounds: CGRect {
        var s = session.state
        s.cropRect = nil
        s.background = BackgroundSettings()
        return s.contentBounds(expand: session.expandCanvas)
    }

    private func enterCrop() {
        session.selection = []
        isCropping = true
        cropWorking = session.state.cropRect ?? session.state.imageRect
        cropAspect = nil
        relayout()
        onCropChange?(cropWorking)
    }

    private func exitCrop() {
        isCropping = false
        drag = .none
        relayout()
    }

    /// Enters crop mode remembering the tool to return to.
    func startCrop() {
        if session.tool != .crop { toolBeforeCrop = session.tool }
        session.tool = .crop
    }

    func applyCrop() {
        let full = uncroppedBounds
        let r = Geo.pixelAligned(cropWorking, scale: session.state.scale)
        let crop: CGRect? = (abs(r.minX - session.state.imageRect.minX) < 0.5 && abs(r.minY) < 0.5 &&
                             abs(r.width - session.state.imageRect.width) < 0.5 && abs(r.height - session.state.imageRect.height) < 0.5 &&
                             full.equalTo(session.state.imageRect)) ? nil : r
        session.apply { $0.cropRect = crop }
        session.tool = toolBeforeCrop == .crop ? .select : toolBeforeCrop
    }

    func cancelCrop() {
        session.tool = toolBeforeCrop == .crop ? .select : toolBeforeCrop
    }

    func resetCrop() { setCrop(session.state.imageRect) }

    /// Sets the working crop rect (clamped to the uncropped canvas).
    func setCrop(_ r: CGRect) {
        let limit = uncroppedBounds
        var c = r.standardized
        c.size.width = min(max(c.width, 1 / session.state.scale), limit.width)
        c.size.height = min(max(c.height, 1 / session.state.scale), limit.height)
        c.origin.x = min(max(c.minX, limit.minX), limit.maxX - c.width)
        c.origin.y = min(max(c.minY, limit.minY), limit.maxY - c.height)
        cropWorking = c
        onCropChange?(c)
        needsDisplay = true
    }

    private func cropSnapLines() -> ([CGFloat], [CGFloat]) {
        let img = session.state.imageRect
        var xs = [img.minX, img.midX, img.maxX], ys = [img.minY, img.midY, img.maxY]
        for o in session.state.objects {
            let f = o.frame
            xs += [f.minX, f.maxX]; ys += [f.minY, f.maxY]
        }
        return (xs, ys)
    }

    private func cropMouseDown(_ p: CGPoint) {
        let v = viewRect(cropWorking)
        let pv = viewPoint(p)
        if let h = Geo.RectHandle.allCases.first(where: { Geo.dist($0.point(in: v), pv) <= 12 / magnification }) {
            drag = .cropHandle(h, original: cropWorking)
        } else if cropWorking.contains(p) {
            drag = .cropMove(start: p, original: cropWorking)
        } else {
            drag = .cropNew(anchor: p)
        }
    }

    private func cropDragged(_ raw: CGPoint, shift: Bool, option: Bool, snap: Bool) {
        let doSnap = snap && Defaults[.annotateSnapCrop]
        let (xs, ys) = cropSnapLines()
        let threshold = 6 / magnification
        let p = doSnap ? Snapping.snap(raw, xs: xs, ys: ys, threshold: threshold) : raw
        switch drag {
        case .cropMove(let start, let original):
            var r = original.offsetBy(dx: raw.x - start.x, dy: raw.y - start.y)
            if doSnap {
                let res = Snapping.snap(r, targets: [], canvas: session.state.imageRect, threshold: threshold)
                r = r.offsetBy(dx: res.offset.dx, dy: res.offset.dy)
            }
            setCrop(r)
        case .cropHandle(let h, let original):
            var base = original
            if let a = cropAspect, abs(base.width / max(base.height, 0.001) - a) > 0.001 { base = Geo.fit(ratio: a, in: base) }
            setCrop(Geo.resize(base, handle: h, to: p, keepAspect: cropAspect != nil || shift, fromCenter: option))
        case .cropNew(let anchor):
            var (s, e) = Geo.dragRect(from: anchor, to: p, square: shift, fromCenter: option)
            if let a = cropAspect {
                let w = abs(e.x - s.x)
                e.y = s.y + (e.y >= s.y ? 1 : -1) * w / a
            }
            setCrop(Geo.rect(s, e))
        default:
            break
        }
    }

    // MARK: Drag & drop

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        return urls.filter { u in
            u.pathExtension.lowercased() == ShotcraftDocument.fileExtension ||
                (UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) ?? false)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return droppedURLs(sender).isEmpty && NSImage(pasteboard: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = docPoint(convert(sender.draggingLocation, from: nil))
        let urls = droppedURLs(sender)
        if !urls.isEmpty { onDropFiles?(urls, p); return true }
        if let img = NSImage(pasteboard: sender.draggingPasteboard), let cg = img.bestCGImage {
            session.addImageObject(cg.image, scale: cg.scale, center: p)
            return true
        }
        return false
    }
}

// MARK: - Inline text view

/// NSTextView used for in-place text editing (CleanShot: `ANTextView`). Esc / ⌘↩ finish editing.
@MainActor
final class InlineTextView: NSTextView {
    var onFinish: (() -> Void)?

    func configure(for a: Annotation, keepText: Bool = false) {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        usesFontPanel = false
        let pad = TextLayout.padding(a)
        textContainerInset = NSSize(width: pad, height: pad)
        textContainer?.lineFragmentPadding = 0
        if let w = a.textWidth {
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(width: max(1, w - pad * 2), height: 100_000)
        } else {
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
        }
        isHorizontallyResizable = false
        isVerticallyResizable = false
        var attrs = TextLayout.attributes(a)
        if a.textStyle == .outline {
            attrs[.strokeColor] = NSColor(srgbRed: a.color.r, green: a.color.g, blue: a.color.b, alpha: 1)
            attrs[.strokeWidth] = -6.0
        }
        typingAttributes = attrs
        if !keepText { string = a.text }
        textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: (string as NSString).length))
        insertionPointColor = TextLayout.textColor(a)
        if a.textStyle.hasBox {
            drawsBackground = true
            backgroundColor = NSColor(srgbRed: a.color.r, green: a.color.g, blue: a.color.b, alpha: a.color.a)
        } else {
            drawsBackground = false
        }
        wantsLayer = true
        layer?.cornerRadius = a.textStyle.hasBox ? min(a.fontSize * 0.3, frame.height / 2) : 0
    }

    override func cancelOperation(_ sender: Any?) { onFinish?() }

}

// MARK: - Helpers

extension NSImage {
    /// The highest-resolution bitmap of the image and its pixels-per-point.
    var bestCGImage: (image: CGImage, scale: CGFloat)? {
        let reps = representations.filter { $0.pixelsWide > 0 }
        let best = reps.max { $0.pixelsWide < $1.pixelsWide }
        var rect = CGRect(origin: .zero, size: size)
        if let b = best, size.width > 0 {
            let scale = max(1, (CGFloat(b.pixelsWide) / size.width).rounded())
            rect.size = CGSize(width: CGFloat(b.pixelsWide) / scale, height: CGFloat(b.pixelsHigh) / scale)
            if let bitmap = b as? NSBitmapImageRep, let cg = bitmap.cgImage { return (cg, scale) }
            if let cg = b.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return (cg, scale) }
        }
        guard let cg = cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return (cg, max(1, CGFloat(cg.width) / max(size.width, 1)))
    }
}
