import AppKit
import SuperScreenshotCore

/// Crop & Resize controls shown in the toolbar while cropping (CleanShot `ANCropController`): ratio menu (with
/// snapping), W ⇄ H fields, "Image size" popup that opens the Resize popover, and Reset.
@MainActor
final class CropBar: NSStackView {
    private let session: EditorSession
    private unowned let canvas: CanvasView
    private let ratio = NSPopUpButton(frame: .zero, pullsDown: true)
    private let wField = CropBar.field()
    private let hField = CropBar.field()
    private let sizeButton = NSButton(title: "", target: nil, action: nil)
    private var ratioIndex = 0
    private var popover: NSPopover?

    private static let ratios: [(String, CGFloat?)] = [
        ("Freeform", nil), ("Original", -1), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:10", 1.6), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]

    init(session: EditorSession, canvas: CanvasView) {
        self.session = session
        self.canvas = canvas
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY

        ratio.bezelStyle = .texturedRounded
        ratio.toolTip = "Aspect ratio"
        ratio.widthAnchor.constraint(equalToConstant: 104).isActive = true
        rebuildRatioMenu()

        for f in [wField, hField] {
            f.onAction { [weak self] _ in self?.commitFields() }
        }
        wField.toolTip = "Crop width in pixels"
        hField.toolTip = "Crop height in pixels"
        let swap = UI.symbolButton("arrow.left.arrow.right", tooltip: "Swap width and height") { [weak self] in self?.swap() }

        sizeButton.bezelStyle = .texturedRounded
        sizeButton.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        sizeButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        sizeButton.imagePosition = .imageTrailing
        sizeButton.toolTip = "Resize the image"
        sizeButton.onAction { [weak self] _ in self?.showResize() }

        let reset = UI.symbolButton("arrow.counterclockwise", tooltip: "Reset the crop") { [weak self] in
            guard let self else { return }
            self.selectRatio(0)
            self.canvas.resetCrop()
        }

        for v in [ratio, wField, swap, hField, UI.label("px"), UI.separator(), UI.label("Image size:", size: 12), sizeButton, reset] as [NSView] {
            addArrangedSubview(v)
        }
        canvas.onCropChange = { [weak self] r in self?.updateFields(r) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func field() -> NSTextField {
        let f = NSTextField(string: "")
        f.alignment = .center
        f.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let fmt = NumberFormatter()
        fmt.minimum = 1; fmt.maximum = 100_000; fmt.allowsFloats = false
        f.formatter = fmt
        f.widthAnchor.constraint(equalToConstant: 58).isActive = true
        return f
    }

    /// Called when crop mode starts.
    func reset() {
        popover?.close()
        selectRatio(0)
        updateFields(canvas.cropWorking)
    }

    private func rebuildRatioMenu() {
        let m = NSMenu()
        m.addItem(withTitle: Self.ratios[ratioIndex].0, action: nil, keyEquivalent: "")  // pull-down title
        for (i, r) in Self.ratios.enumerated() {
            let item = NSMenuItem(title: r.0, key: "", modifiers: []) { [weak self] in self?.selectRatio(i) }
            item.state = i == ratioIndex ? .on : .off
            m.addItem(item)
            if i == 1 { m.addItem(.separator()) }
        }
        m.addItem(.separator())
        let snap = NSMenuItem(title: "Snap to Edges", key: "", modifiers: []) { [weak self] in
            Defaults[.annotateSnapCrop].toggle()
            self?.rebuildRatioMenu()
        }
        snap.state = Defaults[.annotateSnapCrop] ? .on : .off
        snap.toolTip = "Snap the crop to the image edges and centre (hold ⌘ to disable temporarily)"
        m.addItem(snap)
        ratio.menu = m
    }

    private func selectRatio(_ i: Int) {
        ratioIndex = i
        var r = Self.ratios[i].1
        if r == -1 { r = session.state.imageSize.width / max(session.state.imageSize.height, 1) }
        canvas.cropAspect = r
        rebuildRatioMenu()
    }

    private func commitFields() {
        let sc = session.state.scale
        var r = canvas.cropWorking
        r.size = CGSize(width: CGFloat(max(1, wField.integerValue)) / sc, height: CGFloat(max(1, hField.integerValue)) / sc)
        selectRatio(0)
        canvas.setCrop(r)
        canvas.window?.makeFirstResponder(canvas)
    }

    private func swap() {
        let r = canvas.cropWorking
        if let a = canvas.cropAspect {
            canvas.cropAspect = 1 / a
            if ratioIndex > 1, let flipped = Self.ratios.firstIndex(where: { $0.1.map { abs($0 - 1 / a) < 0.001 } ?? false }) {
                ratioIndex = flipped
            }
            rebuildRatioMenu()
        }
        canvas.setCrop(CGRect(x: r.midX - r.height / 2, y: r.midY - r.width / 2, width: r.height, height: r.width))
    }

    func updateFields(_ r: CGRect) {
        let sc = session.state.scale
        if wField.currentEditor() == nil { wField.integerValue = Int((r.width * sc).rounded()) }
        if hField.currentEditor() == nil { hField.integerValue = Int((r.height * sc).rounded()) }
        sizeButton.title = "\(session.state.image.width) × \(session.state.image.height) px"
    }

    private func showResize() {
        let vc = ResizeController(pixelSize: CGSize(width: session.state.image.width, height: session.state.image.height),
                                  hasAnnotations: !session.state.objects.isEmpty) { [weak self] size, flatten in
            guard let self else { return }
            self.popover?.close()
            guard let size else { return }
            self.session.resizeImage(to: size, flatten: flatten)
            self.canvas.resetCrop()
            self.canvas.relayout()
            self.updateFields(self.canvas.cropWorking)
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: sizeButton.bounds, of: sizeButton, preferredEdge: .maxY)
        popover = p
    }
}

/// Resize popover (CleanShot `ANResizeControlViewController`): Width / Height with a proportion lock, pixels or
/// percent, "Flatten Annotations", Cancel / Resize. Calls back with nil on Cancel.
@MainActor
final class ResizeController: NSViewController {
    private let original: CGSize
    private let hasAnnotations: Bool
    private let onFinish: (CGSize?, Bool) -> Void
    private var locked = true
    private var percent = false
    private var current = CGSize.zero
    private let wField = NSTextField(string: "")
    private let hField = NSTextField(string: "")

    init(pixelSize: CGSize, hasAnnotations: Bool, onFinish: @escaping (CGSize?, Bool) -> Void) {
        self.original = pixelSize
        self.hasAnnotations = hasAnnotations
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        current = original
        let fmt = NumberFormatter()
        fmt.minimum = 1; fmt.maximum = 100_000; fmt.maximumFractionDigits = 1
        for f in [wField, hField] {
            f.formatter = fmt
            f.alignment = .right
            f.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            f.widthAnchor.constraint(equalToConstant: 80).isActive = true
            f.delegate = self
        }
        let unit = UI.popup(["pixels", "percent"], selected: 0, tooltip: "Unit") { [weak self] i in
            self?.percent = i == 1
            self?.refresh()
        }
        let lock = NSButton(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Keep proportions") ?? NSImage(),
                            target: nil, action: nil)
        lock.alternateImage = NSImage(systemSymbolName: "lock.open", accessibilityDescription: "Free proportions")
        lock.setButtonType(.toggle)
        lock.isBordered = false
        lock.state = .off
        lock.toolTip = "Keep proportions"
        lock.onAction { [weak self] s in self?.locked = (s as? NSButton)?.state == .off }

        let grid = NSGridView(views: [
            [UI.label("Width:", size: 13, color: .labelColor), wField, lock],
            [UI.label("Height:", size: 13, color: .labelColor), hField, unit],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let flatten = NSButton(checkboxWithTitle: "Flatten Annotations", target: nil, action: nil)
        flatten.state = .off
        flatten.isEnabled = hasAnnotations
        let note = UI.label("Burns annotations into the image so they scale with it")
        let cancel = UI.textButton("Cancel") { [weak self] in self?.onFinish(nil, false) }
        cancel.keyEquivalent = "\u{1b}"
        let resize = UI.textButton("Resize") { [weak self, weak flatten] in
            guard let self else { return }
            self.commitFieldEdits()
            self.onFinish(self.current, flatten?.state == .on)
        }
        resize.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, resize])
        let root = NSStackView(views: [grid, flatten, note, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
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
