import AppKit
import ShotcraftCore

/// Second toolbar row: properties of the active tool, or of the selected objects (changes apply to both
/// the selection and the tool's remembered style). In crop mode it shows the crop/resize controls.
@MainActor
final class PropertiesBar: NSView {
    private let session: EditorSession
    private unowned let canvas: CanvasView
    private let bridge: ColorPanelBridge
    private let stack = NSStackView()
    private var popover: NSPopover?

    // Crop controls (kept to update live)
    private var cropW: NSTextField?
    private var cropH: NSTextField?

    init(session: EditorSession, canvas: CanvasView, bridge: ColorPanelBridge) {
        self.session = session
        self.canvas = canvas
        self.bridge = bridge
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        session.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .tool, .selection: self.rebuild()
            case .content:
                // Undo/redo may change the selection's style; don't rebuild under an active slider drag.
                if NSEvent.pressedMouseButtons == 0 && !session.isInteracting { self.rebuild() }
            case .style: break
            }
        }
        canvas.onCropChange = { [weak self] r in self?.updateCropFields(r) }
        rebuild()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Context

    /// The tool whose properties are shown: the selection's kind if there is one, else the active tool.
    private var targetTool: AnnotateTool {
        if let first = session.selectedObjects.first, first.kind != .image { return AnnotateTool.forKind(first.kind) }
        return session.tool
    }

    private var sample: Annotation? {
        let kind = targetTool.kind
        return session.selectedObjects.first { $0.kind == kind }
    }

    private func change(coalesce: String? = nil, style: (inout ToolStyle) -> Void, object: @escaping (inout Annotation) -> Void) {
        let tool = targetTool
        session.updateStyle(for: tool, style)
        let kind = tool.kind
        session.modifySelection(coalesce: coalesce) { a in if a.kind == kind { object(&a) } }
        canvas.refreshTextEditor()
        // Hand the keyboard back to the canvas so single-key tool shortcuts keep working.
        if canvas.editingID == nil, NSEvent.pressedMouseButtons == 0 { canvas.window?.makeFirstResponder(canvas) }
    }

    // MARK: Build

    func rebuild() {
        popover?.close()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cropW = nil; cropH = nil
        if session.tool == .crop { buildCropBar(); return }

        let selected = session.selectedObjects
        if !selected.isEmpty, selected.allSatisfy({ $0.kind == .image }) { buildImageBar(selected); return }

        let tool = targetTool
        let st = session.style(for: tool)
        let s = sample

        if tool == .select {
            stack.addArrangedSubview(UI.label("Click an object to select it · ⇧-click or drag to select several · ⌥-drag duplicates"))
            return
        }

        let title = UI.label(tool.title, size: 12, color: .labelColor)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(title)

        let colorable: Set<AnnotateTool> = [.rectangle, .filledRectangle, .ellipse, .line, .arrow, .text, .pen, .highlighter, .counter]
        if colorable.contains(tool) {
            let current = s?.color ?? st.color
            let well = ColorWellButton(color: current) { [weak self] button in self?.showPalette(from: button) }
            stack.addArrangedSubview(well)
        }

        let widthTools: Set<AnnotateTool> = [.rectangle, .ellipse, .line, .arrow, .pen, .highlighter]
        if widthTools.contains(tool), !(tool == .highlighter && (s?.highlightShape ?? st.highlightShape) == .rectangle) {
            let w = s?.lineWidth ?? st.lineWidth
            let items = ToolStyle.widths.map { "\(Int($0)) pt" }
            let idx = ToolStyle.widths.firstIndex { abs($0 - w) < 0.01 } ?? ToolStyle.widths.firstIndex { $0 >= w } ?? 3
            stack.addArrangedSubview(UI.label("Width"))
            stack.addArrangedSubview(UI.popup(items, selected: idx, tooltip: "Thickness ([ / ])") { [weak self] i in
                let v = ToolStyle.widths[i]
                self?.change(style: { $0.lineWidth = v }, object: { $0.lineWidth = v })
            })
        }

        switch tool {
        case .arrow:
            let cur = s?.arrowStyle ?? st.arrowStyle
            stack.addArrangedSubview(UI.popup(ArrowStyle.allCases.map(\.title), selected: ArrowStyle.allCases.firstIndex(of: cur) ?? 0,
                                              tooltip: "Arrow style") { [weak self] i in
                let v = ArrowStyle.allCases[i]
                self?.change(style: { $0.arrowStyle = v }, object: { a in
                    a.arrowStyle = v
                    if v == .curved && a.control == nil {
                        let mid = Geo.mid(a.start, a.end), d = Geo.sub(a.end, a.start)
                        a.control = CGPoint(x: mid.x - d.dy * 0.2, y: mid.y + d.dx * 0.2)
                    }
                })
            })
            let inverse = NSButton(checkboxWithTitle: "Reverse", target: nil, action: nil)
            inverse.controlSize = .small
            inverse.toolTip = "Draw the head where the drag starts (Settings → Annotate → Inverse arrow direction)"
            inverse.state = (s?.inverseArrow ?? Defaults[.annotateInverseArrow]) ? .on : .off
            inverse.onAction { [weak self] sender in
                let on = (sender as? NSButton)?.state == .on
                if self?.session.selection.isEmpty ?? true { Defaults[.annotateInverseArrow] = on }
                self?.session.modifySelection { if $0.kind == .arrow { $0.inverseArrow = on } }
            }
            stack.addArrangedSubview(inverse)
        case .text:
            let cur = s?.textStyle ?? st.textStyle
            stack.addArrangedSubview(UI.popup(TextStyle.allCases.map(\.title), selected: TextStyle.allCases.firstIndex(of: cur) ?? 0,
                                              tooltip: "Text style") { [weak self] i in
                let v = TextStyle.allCases[i]
                self?.change(style: { $0.textStyle = v }, object: { $0.textStyle = v })
            })
            let size = s?.fontSize ?? st.fontSize
            let sizes = ToolStyle.fontSizes
            stack.addArrangedSubview(UI.label("Size"))
            stack.addArrangedSubview(UI.popup(sizes.map { "\(Int($0))" }, selected: sizes.firstIndex { $0 >= size - 0.01 } ?? 5,
                                              tooltip: "Font size ([ / ])") { [weak self] i in
                let v = sizes[i]
                self?.change(style: { $0.fontSize = v }, object: { $0.fontSize = v })
            })
            let emoji = UI.symbolButton("face.smiling", tooltip: "Emoji & Symbols") { [weak self] in
                guard let self else { return }
                if self.canvas.editingID == nil {
                    if let id = self.session.selection.first, self.session.object(id)?.kind == .text {
                        self.canvas.beginTextEditing(id, startState: nil)
                    } else { NSSound.beep(); return }
                }
                NSApp.orderFrontCharacterPalette(nil)
            }
            stack.addArrangedSubview(emoji)
        case .pixelate:
            let cur = s?.pixelateStyle ?? st.pixelateStyle
            stack.addArrangedSubview(UI.popup(PixelateStyle.allCases.map(\.title), selected: PixelateStyle.allCases.firstIndex(of: cur) ?? 0,
                                              tooltip: "Style") { [weak self] i in
                let v = PixelateStyle.allCases[i]
                self?.change(style: { $0.pixelateStyle = v }, object: { $0.pixelateStyle = v })
            })
            stack.addArrangedSubview(UI.label("Intensity"))
            stack.addArrangedSubview(UI.slider(value: s?.intensity ?? st.intensity, min: 0, max: 1, tooltip: "Intensity") { [weak self] v in
                self?.change(coalesce: "intensity", style: { $0.intensity = v }, object: { $0.intensity = v })
            })
        case .spotlight:
            let cur = s?.spotlightShape ?? st.spotlightShape
            stack.addArrangedSubview(UI.popup(SpotlightShape.allCases.map(\.title), selected: SpotlightShape.allCases.firstIndex(of: cur) ?? 0,
                                              tooltip: "Shape") { [weak self] i in
                let v = SpotlightShape.allCases[i]
                self?.change(style: { $0.spotlightShape = v }, object: { $0.spotlightShape = v })
            })
            stack.addArrangedSubview(UI.label("Dimming"))
            stack.addArrangedSubview(UI.slider(value: session.state.spotlightOpacity, min: 0.1, max: 0.95, tooltip: "Opacity of the dimmed area") { [weak self] v in
                self?.session.applyCoalescing("spotlightOpacity") { $0.spotlightOpacity = v }
            })
        case .counter:
            let cur = s?.counterStyle ?? st.counterStyle
            stack.addArrangedSubview(UI.popup(CounterStyle.allCases.map(\.title), selected: CounterStyle.allCases.firstIndex(of: cur) ?? 0,
                                              tooltip: "Counter style") { [weak self] i in
                let v = CounterStyle.allCases[i]
                // Style applies to every counter so the sequence stays consistent.
                self?.session.updateStyle(for: .counter) { $0.counterStyle = v }
                self?.session.apply { s in for i in s.objects.indices where s.objects[i].kind == .counter { s.objects[i].counterStyle = v } }
            })
            let size = s?.fontSize ?? st.counterSize
            let sizes = ToolStyle.counterSizes
            stack.addArrangedSubview(UI.label("Size"))
            stack.addArrangedSubview(UI.popup(sizes.map { "\(Int($0))" }, selected: sizes.firstIndex { $0 >= size - 0.01 } ?? 3, tooltip: "Size") { [weak self] i in
                let v = sizes[i]
                self?.change(style: { $0.counterSize = v }, object: { $0.fontSize = v })
            })
            stack.addArrangedSubview(UI.label("Starting number:"))
            let field = NSTextField(string: "\(session.state.counterStart)")
            field.controlSize = .small
            field.alignment = .right
            field.formatter = {
                let f = NumberFormatter(); f.minimum = 0; f.maximum = 9999; f.allowsFloats = false; return f
            }()
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let stepper = NSStepper()
            stepper.controlSize = .small
            stepper.minValue = 0; stepper.maxValue = 9999; stepper.increment = 1
            stepper.integerValue = session.state.counterStart
            let apply: (Int) -> Void = { [weak self] n in
                guard let self else { return }
                field.integerValue = n; stepper.integerValue = n
                // Renumber existing counters from the new start, keeping their order.
                self.session.apply { s in
                    let delta = n - s.counterStart
                    s.counterStart = n
                    for i in s.objects.indices where s.objects[i].kind == .counter { s.objects[i].number += delta }
                }
            }
            field.onAction { _ in apply(field.integerValue) }
            stepper.onAction { _ in apply(stepper.integerValue) }
            stack.addArrangedSubview(field)
            stack.addArrangedSubview(stepper)
        case .highlighter:
            let cur = s?.highlightShape ?? st.highlightShape
            stack.addArrangedSubview(UI.popup(HighlightShape.allCases.map(\.title), selected: HighlightShape.allCases.firstIndex(of: cur) ?? 0,
                                              tooltip: "Shape") { [weak self] i in
                let v = HighlightShape.allCases[i]
                self?.session.updateStyle(for: .highlighter) { $0.highlightShape = v }
                self?.rebuild()
            })
            stack.addArrangedSubview(UI.label("Opacity"))
            stack.addArrangedSubview(UI.slider(value: s?.opacity ?? st.highlightOpacity, min: 0.15, max: 1, tooltip: "Opacity") { [weak self] v in
                self?.change(coalesce: "hlOpacity", style: { $0.highlightOpacity = v }, object: { $0.opacity = v })
            })
        default:
            break
        }

        let shadowTools: Set<AnnotateTool> = [.rectangle, .filledRectangle, .ellipse, .line, .arrow, .text, .pen, .counter]
        if shadowTools.contains(tool) {
            stack.addArrangedSubview(UI.separator())
            stack.addArrangedSubview(shadowToggle(on: s?.shadow ?? Defaults[.annotateDrawShadow]))
        }
    }

    private func shadowToggle(on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
        b.controlSize = .small
        b.state = on ? .on : .off
        b.toolTip = "Draw a drop shadow under annotations"
        b.onAction { [weak self] sender in
            let v = (sender as? NSButton)?.state == .on
            Defaults[.annotateDrawShadow] = v
            self?.session.modifySelection { $0.shadow = v }
        }
        return b
    }

    private func buildImageBar(_ selected: [Annotation]) {
        let title = UI.label("Image", size: 12, color: .labelColor)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(UI.label("Opacity"))
        stack.addArrangedSubview(UI.slider(value: selected[0].opacity, min: 0.1, max: 1, tooltip: "Opacity") { [weak self] v in
            self?.session.modifySelection(coalesce: "imageOpacity") { if $0.kind == .image { $0.opacity = v } }
        })
        stack.addArrangedSubview(UI.separator())
        stack.addArrangedSubview(shadowToggle(on: selected[0].shadow))
        stack.addArrangedSubview(UI.label("Drag a corner to scale · ⇧ to stretch"))
    }

    private func showPalette(from button: ColorWellButton) {
        let current = button.color
        let vc = ColorPaletteController(current: current, bridge: bridge) { [weak self, weak button] c in
            button?.color = c
            self?.change(coalesce: "color", style: { $0.color = c }, object: { $0.color = c })
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover = p
    }

    // MARK: Crop bar

    private static let cropRatios: [(String, CGFloat?)] = [
        ("Freeform", nil), ("Original", -1), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:10", 1.6), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]

    private func buildCropBar() {
        let title = UI.label("Crop & Resize", size: 12, color: .labelColor)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(title)

        let ratio = UI.popup(Self.cropRatios.map(\.0), selected: 0, tooltip: "Aspect ratio") { [weak self] i in
            guard let self else { return }
            var r = Self.cropRatios[i].1
            if r == -1 { r = self.session.state.imageSize.width / max(self.session.state.imageSize.height, 1) }
            self.canvas.cropAspect = r
        }
        stack.addArrangedSubview(ratio)

        let formatter = NumberFormatter()
        formatter.minimum = 1; formatter.maximum = 100_000; formatter.allowsFloats = false
        func field() -> NSTextField {
            let f = NSTextField(string: "")
            f.controlSize = .small
            f.alignment = .right
            f.formatter = formatter
            f.widthAnchor.constraint(equalToConstant: 60).isActive = true
            return f
        }
        let w = field(), h = field()
        let commit: () -> Void = { [weak self] in
            guard let self else { return }
            let sc = self.session.state.scale
            var r = self.canvas.cropWorking
            let nw = CGFloat(max(1, w.integerValue)) / sc, nh = CGFloat(max(1, h.integerValue)) / sc
            r.size = CGSize(width: nw, height: nh)
            self.canvas.cropAspect = nil
            ratio.selectItem(at: 0)
            self.canvas.setCrop(r)
        }
        w.onAction { _ in commit() }
        h.onAction { _ in commit() }
        cropW = w; cropH = h
        stack.addArrangedSubview(w)
        stack.addArrangedSubview(UI.label("×"))
        stack.addArrangedSubview(h)
        stack.addArrangedSubview(UI.label("px"))
        stack.addArrangedSubview(UI.symbolButton("arrow.left.arrow.right", tooltip: "Swap width and height") { [weak self] in
            guard let self else { return }
            let r = self.canvas.cropWorking
            if let a = self.canvas.cropAspect { self.canvas.cropAspect = 1 / a }
            self.canvas.setCrop(CGRect(x: r.midX - r.height / 2, y: r.midY - r.width / 2, width: r.height, height: r.width))
        })
        let snap = NSButton(checkboxWithTitle: "Snap", target: nil, action: nil)
        snap.controlSize = .small
        snap.toolTip = "Snap the crop to the image edges and centre (hold ⌘ to disable temporarily)"
        snap.state = Defaults[.annotateSnapCrop] ? .on : .off
        snap.onAction { s in Defaults[.annotateSnapCrop] = (s as? NSButton)?.state == .on }
        stack.addArrangedSubview(snap)
        stack.addArrangedSubview(UI.separator())
        let resize = UI.textButton("Resize…", symbol: "arrow.up.left.and.arrow.down.right") { }
        resize.controlSize = .small
        resize.onAction { [weak self, weak resize] _ in
            guard let self, let resize else { return }
            self.showResize(from: resize)
        }
        stack.addArrangedSubview(resize)
        stack.addArrangedSubview(UI.separator())
        let reset = UI.textButton("Reset") { [weak self] in self?.canvas.resetCrop() }
        reset.controlSize = .small
        let cancel = UI.textButton("Cancel") { [weak self] in self?.canvas.cancelCrop() }
        cancel.controlSize = .small
        let apply = UI.textButton("Apply") { [weak self] in self?.canvas.applyCrop() }
        apply.controlSize = .small
        apply.bezelColor = .controlAccentColor
        apply.toolTip = "Apply crop (Return)"
        stack.addArrangedSubview(reset)
        stack.addArrangedSubview(cancel)
        stack.addArrangedSubview(apply)
        updateCropFields(canvas.cropWorking)
    }

    private func updateCropFields(_ r: CGRect) {
        let sc = session.state.scale
        if let w = cropW, w.currentEditor() == nil { w.integerValue = Int((r.width * sc).rounded()) }
        if let h = cropH, h.currentEditor() == nil { h.integerValue = Int((r.height * sc).rounded()) }
    }

    private func showResize(from button: NSButton) {
        let vc = ResizeController(pixelSize: CGSize(width: session.state.image.width, height: session.state.image.height),
                                  hasAnnotations: !session.state.objects.isEmpty) { [weak self] size, flatten in
            guard let self else { return }
            self.popover?.close()
            self.session.resizeImage(to: size, flatten: flatten)
            self.canvas.resetCrop()
            self.canvas.relayout()
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover = p
    }
}

/// Resize popover (CleanShot `ANResizeControlViewController`: Width/Height, pixels/percent, proportion lock,
/// "Flatten Annotations").
@MainActor
final class ResizeController: NSViewController {
    private let original: CGSize
    private let hasAnnotations: Bool
    private let onResize: (CGSize, Bool) -> Void
    private var locked = true
    private var percent = false
    private let wField = NSTextField(string: "")
    private let hField = NSTextField(string: "")

    init(pixelSize: CGSize, hasAnnotations: Bool, onResize: @escaping (CGSize, Bool) -> Void) {
        self.original = pixelSize
        self.hasAnnotations = hasAnnotations
        self.onResize = onResize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var current = CGSize.zero

    override func loadView() {
        current = original
        let fmt = NumberFormatter()
        fmt.minimum = 1; fmt.maximum = 100_000; fmt.maximumFractionDigits = 1
        for f in [wField, hField] {
            f.formatter = fmt
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        let unit = UI.popup(["pixels", "percent"], selected: 0, tooltip: "Unit") { [weak self] i in
            self?.percent = i == 1
            self?.refresh()
        }
        let lock = NSButton(checkboxWithTitle: "Keep proportions", target: nil, action: nil)
        lock.state = .on
        lock.onAction { [weak self] s in self?.locked = (s as? NSButton)?.state == .on }
        wField.delegate = self
        hField.delegate = self

        let flatten = NSSwitch()
        flatten.state = .off
        flatten.isEnabled = hasAnnotations
        let flattenLabel = UI.label("Flatten Annotations", size: 12, color: .labelColor)
        let info = UI.label("Burns annotations into the image so they scale with it.")

        let grid = NSGridView(views: [
            [UI.label("Width:", size: 12, color: .labelColor), wField],
            [UI.label("Height:", size: 12, color: .labelColor), hField],
            [NSGridCell.emptyContentView, unit],
            [NSGridCell.emptyContentView, lock],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let flattenRow = NSStackView(views: [flatten, flattenLabel])
        flattenRow.spacing = 6
        let cancel = UI.textButton("Cancel") { [weak self] in self?.dismiss(nil) }
        cancel.keyEquivalent = "\u{1b}"
        let resize = UI.textButton("Resize") { [weak self] in
            guard let self else { return }
            self.commitFieldEdits()
            self.onResize(self.current, flatten.state == .on)
        }
        resize.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, resize])
        let root = NSStackView(views: [grid, flattenRow, info, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)
        view = root
        refresh()
    }

    private func commitFieldEdits() {
        if wField.currentEditor() != nil { edited(width: true) }
        if hField.currentEditor() != nil { edited(width: false) }
    }

    private func refresh() {
        if percent {
            wField.doubleValue = (current.width / original.width * 1000).rounded() / 10
            hField.doubleValue = (current.height / original.height * 1000).rounded() / 10
        } else {
            wField.integerValue = Int(current.width.rounded())
            hField.integerValue = Int(current.height.rounded())
        }
    }

    fileprivate func edited(width: Bool) {
        let field = width ? wField : hField
        let v = CGFloat(max(1, field.doubleValue))
        let px = percent ? (width ? original.width : original.height) * v / 100 : v
        let aspect = original.width / max(original.height, 1)
        if width {
            current.width = px
            if locked { current.height = max(1, (px / aspect).rounded()) }
        } else {
            current.height = px
            if locked { current.width = max(1, (px * aspect).rounded()) }
        }
        refresh()
    }
}

extension ResizeController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        edited(width: f === wField)
    }
}
