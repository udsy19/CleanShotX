import AppKit
import ShotcraftCore

/// Content of the toolbar's tool-style popover (CleanShot `annotateTextStyle` / arrow-style menus): the options of
/// the active tool, or of the selected objects. Changes apply to the selection and to the tool's remembered style.
@MainActor
final class ToolStylePanel: NSViewController {
    private let session: EditorSession
    private unowned let canvas: CanvasView
    private let grid = NSGridView()
    private var rebuildScheduled = false

    init(session: EditorSession, canvas: CanvasView) {
        self.session = session
        self.canvas = canvas
        super.init(nibName: nil, bundle: nil)
        session.observe { [weak self] change in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            // Undo/redo may change the selection's style; never rebuild under an active slider drag.
            if change == .style { return }
            if change == .content && (NSEvent.pressedMouseButtons != 0 || session.isInteracting) { return }
            self.scheduleRebuild()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let box = NSStackView(views: [grid])
        box.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = box
    }

    /// Rebuilds after the current event (controls may be mid-action when the model changes).
    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    private func change(coalesce: String? = nil, style: (inout ToolStyle) -> Void, object: @escaping (inout Annotation) -> Void) {
        session.restyle(coalesce: coalesce, style: style, object: object)
        canvas.refreshTextEditor()
    }

    private func row(_ title: String, _ views: NSView...) {
        let label = UI.label(title, size: 12, color: .secondaryLabelColor)
        let control: NSView
        if views.count == 1 { control = views[0] } else {
            let s = NSStackView(views: views)
            s.spacing = 6
            control = s
        }
        grid.addRow(with: [label, control])
    }

    private func thicknessSlider(_ value: CGFloat, range: ClosedRange<Double> = 1...30) -> NSView {
        let valueLabel = UI.label("\(Int(value)) pt")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let slider = UI.slider(value: Double(value), min: range.lowerBound, max: range.upperBound, width: 140, tooltip: "Thickness ([ / ])") { [weak self, weak valueLabel] v in
            let w = CGFloat(v.rounded())
            valueLabel?.stringValue = "\(Int(w)) pt"
            self?.change(coalesce: "lineWidth", style: { $0.lineWidth = w }, object: { $0.lineWidth = w })
        }
        let s = NSStackView(views: [slider, valueLabel])
        s.spacing = 6
        return s
    }

    func rebuild() {
        _ = view
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        defer { preferredContentSize = view.fittingSize }

        let selected = session.selectedObjects
        if !selected.isEmpty, selected.allSatisfy({ $0.kind == .image }) { buildImage(selected[0]); return }

        let tool = session.styleTarget
        let st = session.style(for: tool)
        let s = session.styleSample

        switch tool {
        case .select, .crop:
            grid.addRow(with: [UI.label("Select an object to change its style.")])
            return
        case .rectangle, .ellipse, .line, .pen:
            row("Thickness:", thicknessSlider(s?.lineWidth ?? st.lineWidth))
        case .filledRectangle:
            break
        case .arrow:
            let cur = s?.arrowStyle ?? st.arrowStyle
            row("Style:", UI.popup(ArrowStyle.allCases.map(\.title), selected: ArrowStyle.allCases.firstIndex(of: cur) ?? 0, tooltip: "Arrow style") { [weak self] i in
                let v = ArrowStyle.allCases[i]
                self?.change(style: { $0.arrowStyle = v }, object: { a in
                    a.arrowStyle = v
                    if v == .curved && a.control == nil {
                        let mid = Geo.mid(a.start, a.end), d = Geo.sub(a.end, a.start)
                        a.control = CGPoint(x: mid.x - d.dy * 0.2, y: mid.y + d.dx * 0.2)
                    }
                })
            })
            row("Thickness:", thicknessSlider(s?.lineWidth ?? st.lineWidth))
            let inverse = NSButton(checkboxWithTitle: "Inverse direction", target: nil, action: nil)
            inverse.controlSize = .small
            inverse.toolTip = "Draw the head where the drag starts"
            inverse.state = (s?.inverseArrow ?? Defaults[.annotateInverseArrow]) ? .on : .off
            inverse.onAction { [weak self] sender in
                guard let self else { return }
                let on = (sender as? NSButton)?.state == .on
                if self.session.selection.isEmpty { Defaults[.annotateInverseArrow] = on }
                self.session.modifySelection { if $0.kind == .arrow { $0.inverseArrow = on } }
            }
            row("", inverse)
        case .text:
            let cur = s?.textStyle ?? st.textStyle
            row("Style:", UI.popup(TextStyle.allCases.map(\.title), selected: TextStyle.allCases.firstIndex(of: cur) ?? 0, tooltip: "Text style") { [weak self] i in
                let v = TextStyle.allCases[i]
                self?.change(style: { $0.textStyle = v }, object: { $0.textStyle = v })
            })
            let size = s?.fontSize ?? st.fontSize
            let sizes = ToolStyle.fontSizes
            let sizePopup = UI.popup(sizes.map { "\(Int($0)) pt" }, selected: sizes.firstIndex { $0 >= size - 0.01 } ?? 5, tooltip: "Font size ([ / ])") { [weak self] i in
                let v = sizes[i]
                self?.change(style: { $0.fontSize = v }, object: { $0.fontSize = v })
            }
            let emoji = UI.symbolButton("face.smiling", tooltip: "Emoji & Symbols") { [weak self] in
                guard let self else { return }
                if self.canvas.editingID == nil {
                    guard let id = self.session.selection.first, self.session.object(id)?.kind == .text else { NSSound.beep(); return }
                    self.canvas.beginTextEditing(id, startState: nil)
                }
                NSApp.orderFrontCharacterPalette(nil)
            }
            row("Size:", sizePopup, emoji)
        case .pixelate:
            let cur = s?.pixelateStyle ?? st.pixelateStyle
            row("Style:", UI.popup(PixelateStyle.allCases.map(\.title), selected: PixelateStyle.allCases.firstIndex(of: cur) ?? 0, tooltip: "Style") { [weak self] i in
                let v = PixelateStyle.allCases[i]
                self?.change(style: { $0.pixelateStyle = v }, object: { $0.pixelateStyle = v })
            })
            row("Intensity:", UI.slider(value: s?.intensity ?? st.intensity, min: 0, max: 1, width: 140, tooltip: "Intensity") { [weak self] v in
                self?.change(coalesce: "intensity", style: { $0.intensity = v }, object: { $0.intensity = v })
            })
        case .spotlight:
            let cur = s?.spotlightShape ?? st.spotlightShape
            row("Shape:", UI.popup(SpotlightShape.allCases.map(\.title), selected: SpotlightShape.allCases.firstIndex(of: cur) ?? 0, tooltip: "Shape") { [weak self] i in
                let v = SpotlightShape.allCases[i]
                self?.change(style: { $0.spotlightShape = v }, object: { $0.spotlightShape = v })
            })
            row("Dimming:", UI.slider(value: session.state.spotlightOpacity, min: 0.1, max: 0.95, width: 140, tooltip: "Opacity of the dimmed area") { [weak self] v in
                self?.session.applyCoalescing("spotlightOpacity") { $0.spotlightOpacity = v }
            })
        case .counter:
            let cur = s?.counterStyle ?? st.counterStyle
            row("Style:", UI.popup(CounterStyle.allCases.map(\.title), selected: CounterStyle.allCases.firstIndex(of: cur) ?? 0, tooltip: "Counter style") { [weak self] i in
                guard let self else { return }
                let v = CounterStyle.allCases[i]
                // Style applies to every counter so the sequence stays consistent.
                self.session.updateStyle(for: .counter) { $0.counterStyle = v }
                self.session.apply { s in for i in s.objects.indices where s.objects[i].kind == .counter { s.objects[i].counterStyle = v } }
            })
            let size = s?.fontSize ?? st.counterSize
            let sizes = ToolStyle.counterSizes
            row("Size:", UI.popup(sizes.map { "\(Int($0)) pt" }, selected: sizes.firstIndex { $0 >= size - 0.01 } ?? 3, tooltip: "Size ([ / ])") { [weak self] i in
                let v = sizes[i]
                self?.change(style: { $0.counterSize = v }, object: { $0.fontSize = v })
            })
            row("Starting number:", counterStartControls())
        case .highlighter:
            let shape = s?.highlightShape ?? st.highlightShape
            row("Shape:", UI.popup(HighlightShape.allCases.map(\.title), selected: HighlightShape.allCases.firstIndex(of: shape) ?? 0, tooltip: "Shape") { [weak self] i in
                let v = HighlightShape.allCases[i]
                self?.session.updateStyle(for: .highlighter) { $0.highlightShape = v }
                self?.scheduleRebuild()
            })
            if shape == .freehand { row("Thickness:", thicknessSlider(s?.lineWidth ?? st.lineWidth, range: 1...24)) }
            row("Opacity:", UI.slider(value: s?.opacity ?? st.highlightOpacity, min: 0.15, max: 1, width: 140, tooltip: "Opacity") { [weak self] v in
                self?.change(coalesce: "hlOpacity", style: { $0.highlightOpacity = v }, object: { $0.opacity = v })
            })
        }

        let shadowTools: Set<AnnotateTool> = [.rectangle, .filledRectangle, .ellipse, .line, .arrow, .text, .pen, .counter]
        if shadowTools.contains(tool) { row("", shadowToggle(on: s?.shadow ?? Defaults[.annotateDrawShadow])) }
    }

    private func counterStartControls() -> NSView {
        let field = NSTextField(string: "\(session.state.counterStart)")
        field.controlSize = .small
        field.alignment = .right
        field.formatter = {
            let f = NumberFormatter(); f.minimum = 0; f.maximum = 9999; f.allowsFloats = false; return f
        }()
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let stepper = NSStepper()
        stepper.controlSize = .small
        stepper.minValue = 0; stepper.maxValue = 9999; stepper.increment = 1
        stepper.integerValue = session.state.counterStart
        let apply: (Int) -> Void = { [weak self, weak field, weak stepper] n in
            guard let self else { return }
            field?.integerValue = n; stepper?.integerValue = n
            // Renumber existing counters from the new start, keeping their order.
            self.session.apply { s in
                let delta = n - s.counterStart
                s.counterStart = n
                for i in s.objects.indices where s.objects[i].kind == .counter { s.objects[i].number += delta }
            }
        }
        field.onAction { [weak field] _ in if let field { apply(field.integerValue) } }
        stepper.onAction { [weak stepper] _ in if let stepper { apply(stepper.integerValue) } }
        let s = NSStackView(views: [field, stepper])
        s.spacing = 4
        return s
    }

    private func shadowToggle(on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: "Drop shadow", target: nil, action: nil)
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

    private func buildImage(_ sample: Annotation) {
        row("Opacity:", UI.slider(value: sample.opacity, min: 0.1, max: 1, width: 140, tooltip: "Opacity") { [weak self] v in
            self?.session.modifySelection(coalesce: "imageOpacity") { if $0.kind == .image { $0.opacity = v } }
        })
        row("", shadowToggle(on: sample.shadow))
        row("", UI.label("Drag a corner to scale · ⇧ to stretch"))
    }
}
