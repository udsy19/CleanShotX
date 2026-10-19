import AppKit
import SuperScreenshotCore

/// One editor's model: the document state, undo history, selection, active tool and per-tool styles
/// (CleanShot: `AnnotateSession` + `AnnotateHistory`). Views observe it through `observe`.
@MainActor
final class EditorSession {
    enum Change { case content, selection, tool, style }

    struct Snapshot {
        var state: CanvasState
        var selection: Set<UUID>
    }

    private(set) var state: CanvasState
    private(set) var history = UndoStack<Snapshot>()
    private(set) var isDirty = false
    let renderer = AnnotateRenderer()

    var selection: Set<UUID> = [] { didSet { if selection != oldValue { notify(.selection) } } }
    var tool: AnnotateTool { didSet { if tool != oldValue { Defaults[.annotateLastTool] = tool.rawValue; notify(.tool) } } }

    private var styles: [String: ToolStyle]
    private var observers: [(Change) -> Void] = []
    private var interactionStart: Snapshot?
    private var lastCoalesceKey: String?
    private var lastCoalesceTime: Date = .distantPast
    private var opaqueCache: (CGImage, CGRect?)?

    init(state: CanvasState) {
        self.state = state
        self.styles = Defaults[.annotateToolStyles]
        let last = AnnotateTool(rawValue: Defaults[.annotateLastTool]) ?? .arrow
        self.tool = last == .crop ? .arrow : last
    }

    func observe(_ f: @escaping (Change) -> Void) { observers.append(f) }
    private func notify(_ c: Change) { observers.forEach { $0(c) } }

    // MARK: Styles

    func style(for tool: AnnotateTool) -> ToolStyle { styles[tool.rawValue] ?? ToolStyle.defaults(for: tool) }

    func updateStyle(for tool: AnnotateTool, _ change: (inout ToolStyle) -> Void) {
        var s = style(for: tool)
        change(&s)
        styles[tool.rawValue] = s
        Defaults[.annotateToolStyles] = styles
        notify(.style)
    }

    /// The tool whose style the toolbar edits: the selection's kind if there is one, else the active tool.
    var styleTarget: AnnotateTool {
        if let first = selectedObjects.first, first.kind != .image { return AnnotateTool.forKind(first.kind) }
        return tool
    }

    /// First selected object of the style target's kind; its values win over the tool's remembered style.
    var styleSample: Annotation? {
        let kind = styleTarget.kind
        return selectedObjects.first { $0.kind == kind }
    }

    /// Changes the style target's remembered style and every selected object of that kind.
    func restyle(coalesce: String? = nil, style: (inout ToolStyle) -> Void, object: @escaping (inout Annotation) -> Void) {
        let target = styleTarget
        updateStyle(for: target, style)
        let kind = target.kind
        modifySelection(coalesce: coalesce) { a in if a.kind == kind { object(&a) } }
    }

    /// Fresh object for `tool` at `p`, carrying the tool's remembered style.
    func makeObject(for tool: AnnotateTool, at p: CGPoint) -> Annotation? {
        guard let kind = tool.kind else { return nil }
        let st = style(for: tool)
        var a = Annotation(kind: kind, start: p, end: p, color: st.color, lineWidth: st.lineWidth,
                           shadow: Defaults[.annotateDrawShadow])
        switch kind {
        case .arrow:
            a.arrowStyle = st.arrowStyle
            a.inverseArrow = Defaults[.annotateInverseArrow]
        case .text:
            a.textStyle = st.textStyle; a.fontSize = st.fontSize
        case .pixelate:
            a.pixelateStyle = st.pixelateStyle; a.intensity = st.intensity; a.shadow = false
        case .spotlight:
            a.spotlightShape = st.spotlightShape; a.shadow = false
        case .counter:
            a.counterStyle = st.counterStyle; a.fontSize = st.counterSize
            a.number = state.objects.nextCounterNumber(start: state.counterStart)
        case .highlighter:
            a.highlightShape = st.highlightShape; a.opacity = st.highlightOpacity; a.shadow = false
            a.smooth = Defaults[.annotateSmoothDrawing]
            if st.highlightShape == .freehand { a.points = [p] }
        case .pen:
            a.smooth = Defaults[.annotateSmoothDrawing]
            a.points = [p]
        default: break
        }
        return a
    }

    // MARK: Mutations

    /// Undoable change. During an interaction (drag, inline text editing) the change joins the interaction's
    /// single undo step instead of recording its own, so the history stays in order.
    func apply(_ change: (inout CanvasState) -> Void) {
        if isInteracting {
            update(change)
            selection = selection.filter { id in state.objects.contains { $0.id == id } }
            return
        }
        let before = Snapshot(state: state, selection: selection)
        change(&state)
        guard !state.isSameContent(as: before.state) else { return }
        history.record(before)
        lastCoalesceKey = nil
        isDirty = true
        selection = selection.filter { id in state.objects.contains { $0.id == id } }
        notify(.content)
    }

    /// Undoable change that merges with the previous one when it has the same key and happens within
    /// a short time (slider drags, repeated nudges).
    func applyCoalescing(_ key: String, _ change: (inout CanvasState) -> Void) {
        let now = Date()
        if !isInteracting, key == lastCoalesceKey, now.timeIntervalSince(lastCoalesceTime) < 0.8 {
            change(&state)
            lastCoalesceTime = now
            isDirty = true
            notify(.content)
            return
        }
        apply(change)
        lastCoalesceKey = key
        lastCoalesceTime = now
    }

    /// Starts a live interaction (drag). Changes made with `update` are recorded as one undo step.
    func beginInteraction() {
        interactionStart = Snapshot(state: state, selection: selection)
    }

    /// Starts an interaction whose undo step restores `start` (e.g. a text object inserted just before).
    func beginInteraction(from start: CanvasState) {
        interactionStart = Snapshot(state: start, selection: selection)
    }

    /// Live, non-recorded change during an interaction.
    func update(_ change: (inout CanvasState) -> Void) {
        change(&state)
        notify(.content)
    }

    func endInteraction() {
        guard let start = interactionStart else { return }
        interactionStart = nil
        guard !state.isSameContent(as: start.state) else { return }
        history.record(start)
        lastCoalesceKey = nil
        isDirty = true
        notify(.content)
    }

    var isInteracting: Bool { interactionStart != nil }

    func undo() {
        guard !isInteracting, let s = history.undo(current: Snapshot(state: state, selection: selection)) else { NSSound.beep(); return }
        restore(s)
    }

    func redo() {
        guard !isInteracting, let s = history.redo(current: Snapshot(state: state, selection: selection)) else { NSSound.beep(); return }
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        state = s.state
        lastCoalesceKey = nil
        isDirty = true
        selection = s.selection.filter { id in state.objects.contains { $0.id == id } }
        notify(.content)
    }

    func markClean() { isDirty = false }

    /// A document reopened from a crash-recovery copy starts out unsaved.
    func markDirty() {
        isDirty = true
        notify(.content)
    }

    // MARK: Layout & export

    var expandCanvas: Bool { Defaults[.annotateExpandCanvas] }

    /// Opaque pixel bounds of the base image (cached per image).
    var opaqueBounds: CGRect? {
        if let (img, r) = opaqueCache, img === state.image { return r }
        let r = ImageAnalysis.opaqueBounds(of: state.image)
        opaqueCache = (state.image, r)
        return r
    }

    func exportLayout() -> CompositionLayout {
        state.layout(expand: expandCanvas, opaqueBounds: state.background.isActive && state.background.autoBalance ? opaqueBounds : nil)
    }

    /// The flattened image at full pixel resolution.
    func flattenedImage() -> CGImage? { renderer.export(state, layout: exportLayout()) }

    // MARK: Selection helpers

    var selectedObjects: [Annotation] { state.objects.filter { selection.contains($0.id) } }

    func object(_ id: UUID) -> Annotation? { state.objects.first { $0.id == id } }

    /// Topmost object under `p`, optionally restricted.
    func hitObject(at p: CGPoint, tolerance: CGFloat, where filter: (Annotation) -> Bool = { _ in true }) -> Annotation? {
        state.objects.reversed().first { filter($0) && $0.hitTest(p, tolerance: tolerance) }
    }

    func selectAll() { selection = Set(state.objects.map(\.id)) }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        apply { $0.objects.removeAll { ids.contains($0.id) } }
        selection = []
    }

    /// Inserts copies of `objects` offset by `offset` and selects them.
    func insert(_ objects: [Annotation], offset: CGVector) {
        var copies: [Annotation] = []
        var next = state.objects.nextCounterNumber(start: state.counterStart)
        for var o in objects {
            o = o.moved(by: offset)
            o.id = UUID()
            if o.kind == .counter { o.number = next; next += 1 }
            copies.append(o)
        }
        apply { $0.objects.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
    }

    func duplicateSelection() { insert(selectedObjects, offset: CGVector(dx: 12, dy: 12)) }

    enum Arrange { case forward, backward, front, back }

    func arrangeSelection(_ how: Arrange) {
        guard !selection.isEmpty else { return }
        let ids = selection
        apply { s in
            var objs = s.objects
            switch how {
            case .front:
                objs = objs.filter { !ids.contains($0.id) } + objs.filter { ids.contains($0.id) }
            case .back:
                objs = objs.filter { ids.contains($0.id) } + objs.filter { !ids.contains($0.id) }
            case .forward:
                for i in stride(from: objs.count - 2, through: 0, by: -1) where ids.contains(objs[i].id) && !ids.contains(objs[i + 1].id) {
                    objs.swapAt(i, i + 1)
                }
            case .backward:
                for i in 1..<max(1, objs.count) where ids.contains(objs[i].id) && !ids.contains(objs[i - 1].id) {
                    objs.swapAt(i, i - 1)
                }
            }
            s.objects = objs
        }
    }

    func nudgeSelection(by d: CGVector) {
        guard !selection.isEmpty else { return }
        let ids = selection
        applyCoalescing("nudge") { s in
            s.objects = s.objects.map { ids.contains($0.id) ? $0.moved(by: d) : $0 }
        }
    }

    /// Applies `change` to every selected object (color/width/style changes from the toolbar).
    func modifySelection(coalesce key: String? = nil, _ change: @escaping (inout Annotation) -> Void) {
        guard !selection.isEmpty else { return }
        let ids = selection
        let body: (inout CanvasState) -> Void = { s in
            for i in s.objects.indices where ids.contains(s.objects[i].id) { change(&s.objects[i]) }
        }
        if let key { applyCoalescing(key, body) } else { apply(body) }
    }

    // MARK: Image objects

    /// Adds an image as a movable object, fitted inside the visible image and centred at `center`.
    func addImageObject(_ image: CGImage, scale: CGFloat, center: CGPoint? = nil) {
        guard let png = ImageTools.pngData(image) else { NSSound.beep(); return }
        var size = CGSize(width: CGFloat(image.width) / max(scale, 1), height: CGFloat(image.height) / max(scale, 1))
        let limit = state.imageSize
        let f = min(1, limit.width * 0.8 / max(size.width, 1), limit.height * 0.8 / max(size.height, 1))
        size = CGSize(width: size.width * f, height: size.height * f)
        let c = center ?? CGPoint(x: state.imageRect.midX, y: state.imageRect.midY)
        var a = Annotation(kind: .image, start: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2),
                           end: CGPoint(x: c.x + size.width / 2, y: c.y + size.height / 2),
                           color: .black, lineWidth: 0, shadow: Defaults[.annotateDrawShadow])
        a.imagePNG = png
        apply { $0.objects.append(a) }
        selection = [a.id]
        tool = .select
    }

    // MARK: Resize (Crop & Resize → Resize…)

    /// Scales the base image to `pixelSize`; objects are scaled with it. `flatten` burns the annotations
    /// into the image first.
    func resizeImage(to pixelSize: CGSize, flatten: Bool) {
        let w = max(1, Int(pixelSize.width.rounded())), h = max(1, Int(pixelSize.height.rounded()))
        var source = state.image
        var objects = state.objects
        if flatten, let flat = renderer.flattenedContent(state) {
            source = flat
            objects = []
        }
        guard w != source.width || h != source.height || flatten else { return }
        // Indexed / CMYK sources can't back an RGBA context; fall back to sRGB.
        guard let ctx = ImageTools.context(width: w, height: h, colorSpace: source.colorSpace)
                ?? ImageTools.context(width: w, height: h) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let resized = ctx.makeImage() else { return }
        let oldRect = state.imageRect
        let fx = CGFloat(w) / CGFloat(state.image.width), fy = CGFloat(h) / CGFloat(state.image.height)
        let newRect = CGRect(x: 0, y: 0, width: oldRect.width * fx, height: oldRect.height * fy)
        let avg = sqrt(fx * fy)
        apply { s in
            s.image = resized
            s.objects = objects.map { o in
                if abs(fx - fy) < 0.0001 { return o.scaled(by: fx) }
                var m = o.mapped(from: oldRect, to: newRect)
                m.lineWidth *= avg
                if m.kind == .text || m.kind == .counter { m.fontSize *= avg; m.textWidth = m.textWidth.map { $0 * fx } }
                return m
            }
            if let c = s.cropRect {
                s.cropRect = CGRect(x: c.minX * fx, y: c.minY * fy, width: c.width * fx, height: c.height * fy)
            }
        }
        selection = []
    }
}
