import AppKit
import SuperScreenshotCore

// MARK: - Colour palette popover

/// CleanShot `ANColorPalette` (4.8 picker): ten default colours and ten "My Colors" slots in two columns, a colour
/// wheel and an expand chevron. Expanded, a saturation/brightness square, hue and alpha sliders, hex, eyedropper,
/// R/G/B/Alpha fields and "Add to My Colors".
@MainActor
final class ColorPaletteController: NSViewController {
    private var color: RGBAColor
    private let bridge: ColorPanelBridge
    private let onPick: (RGBAColor) -> Void
    /// Closes the hosting popover (the eyedropper needs the screen).
    var requestClose: (() -> Void)?
    private var expanded = Defaults[.annotatePaletteExpanded]

    // Expanded picker state (HSB keeps the hue stable at zero saturation/brightness).
    private var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
    private var sbView: SaturationBrightnessView?
    private var hueSlider: ColorSliderView?
    private var alphaSlider: ColorSliderView?
    private var currentDot: SwatchButton?
    private var hexField: NSTextField?
    private var rgbaFields: [NSTextField] = []
    private var presetSwatches: [(RGBAColor, SwatchButton)] = []

    init(current: RGBAColor, bridge: ColorPanelBridge, onPick: @escaping (RGBAColor) -> Void) {
        self.color = current
        self.bridge = bridge
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        syncHSB()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func syncHSB() {
        let ns = UI.nsColor(color.withAlpha(1)).usingColorSpace(.sRGB) ?? .black
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s > 0.001 && b > 0.001 { hue = h }
        sat = s; bri = b
    }

    /// Applies a colour from any control. `fromHSB` keeps the HSB state as the source of truth.
    private func set(_ c: RGBAColor, fromHSB: Bool = false, notify: Bool = true) {
        color = c
        if !fromHSB { syncHSB() }
        refreshPicker()
        if notify { onPick(c) }
    }

    override func loadView() {
        view = NSView()
        build()
    }

    /// (Re)builds the content inside the persistent root view; the popover keeps showing `view`.
    private func build() {
        view.subviews.forEach { $0.removeFromSuperview() }
        sbView = nil; hueSlider = nil; alphaSlider = nil; currentDot = nil; hexField = nil
        let columns = NSStackView(views: [presetColumn(), customColumn()])
        columns.alignment = .top
        columns.spacing = 6

        let wheel = SwatchButton(.wheel, shape: .circle, size: CGSize(width: 26, height: 26), tooltip: "Show Colors") { [weak self] in
            guard let self else { return }
            self.bridge.onColor = { [weak self] c in self?.set(c) }
            self.bridge.showPanel(initial: self.color)
        }
        let chevron = UI.symbolButton(expanded ? "chevron.left" : "chevron.right", tooltip: expanded ? "Hide the color picker" : "Show the color picker") {}
        chevron.isBordered = false
        chevron.onAction { [weak self] _ in self?.toggleExpanded() }
        let bottom = NSStackView(views: [wheel, NSView(), chevron])
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let left = NSStackView(views: [columns, bottom])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        bottom.widthAnchor.constraint(equalTo: columns.widthAnchor).isActive = true

        let root = NSStackView(views: [left])
        root.alignment = .top
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        if expanded {
            let sep = NSBox(); sep.boxType = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
            sep.setContentHuggingPriority(.init(1), for: .vertical)
            root.addArrangedSubview(sep)
            sep.heightAnchor.constraint(equalTo: left.heightAnchor).isActive = true
            root.addArrangedSubview(pickerPane())
        }
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        refreshPicker()
        preferredContentSize = view.fittingSize
    }

    private func presetColumn() -> NSView {
        let showNames = Defaults[.annotateShowColorNames]
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 0
        presetSwatches = []
        for p in ColorPalette.presets {
            let sw = SwatchButton(.color(p.color), shape: .circle, size: CGSize(width: 28, height: 28), tooltip: p.name) { [weak self] in
                guard let self else { return }
                self.set(p.color.withAlpha(self.color.a))
            }
            sw.contentInset = 3
            presetSwatches.append((p.color, sw))
            if showNames {
                let name = UI.label(p.name, size: 12, color: .labelColor)
                let row = NSStackView(views: [sw, name])
                row.spacing = 4
                col.addArrangedSubview(row)
            } else {
                col.addArrangedSubview(sw)
            }
        }
        return col
    }

    private func customColumn() -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.spacing = 0
        let list = Defaults[.annotateCustomColors]
        for i in 0..<ColorPalette.customSlots {
            if i < list.count {
                let c = list[i]
                let sw = SwatchButton(.color(c), shape: .circle, size: CGSize(width: 28, height: 28),
                                      tooltip: ColorPalette.name(of: c) ?? "My color") { [weak self] in self?.set(c) }
                sw.onDelete = { [weak self] in self?.updateCustom { $0.remove(at: i) } }
                sw.onReorder = { [weak self, weak col] p in
                    guard let self, let col else { return }
                    let local = col.convert(p, from: nil)
                    guard let target = col.arrangedSubviews.firstIndex(where: { $0.frame.contains(local) }) else { return }
                    self.updateCustom { list in
                        let moved = list.remove(at: i)
                        list.insert(moved, at: min(target, list.count))
                    }
                }
                sw.onRightClick = { [weak self] in self?.updateCustom { $0.remove(at: i) } }
                sw.contentInset = 3
                col.addArrangedSubview(sw)
            } else {
                let sw = SwatchButton(.empty, shape: .circle, size: CGSize(width: 28, height: 28), tooltip: "Add the current color to My Colors") { [weak self] in
                    self?.addCurrentToCustom()
                }
                sw.contentInset = 3
                col.addArrangedSubview(sw)
            }
        }
        return col
    }

    private func pickerPane() -> NSView {
        let sb = SaturationBrightnessView()
        sb.onChange = { [weak self] s, b in
            guard let self else { return }
            self.sat = s; self.bri = b
            self.set(self.hsbColor(), fromHSB: true)
        }
        sbView = sb
        let hueS = ColorSliderView(kind: .hue)
        hueS.onChange = { [weak self] v in
            guard let self else { return }
            self.hue = v
            self.set(self.hsbColor(), fromHSB: true)
        }
        hueSlider = hueS
        let alphaS = ColorSliderView(kind: .alpha)
        alphaS.onChange = { [weak self] v in
            guard let self else { return }
            self.set(self.color.withAlpha(Double(v)), fromHSB: true)
        }
        alphaSlider = alphaS

        let dot = SwatchButton(.color(color), shape: .circle, size: CGSize(width: 38, height: 38), tooltip: "Current color") {}
        currentDot = dot
        let hex = NSTextField(string: "")
        hex.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hex.alignment = .center
        hex.widthAnchor.constraint(equalToConstant: 76).isActive = true
        hex.onAction { [weak self, weak hex] _ in
            guard let self, let hex, let c = Self.parseHex(hex.stringValue) else { NSSound.beep(); return }
            self.set(c.withAlpha(self.color.a))
        }
        hexField = hex
        let hexCol = labeled(hex, "Hex")
        let pipette = UI.symbolButton("eyedropper", tooltip: "Pick a color from the screen") { [weak self] in
            guard let self else { return }
            self.bridge.onColor = { [weak self] c in
                guard let self else { return }
                let picked = c.withAlpha(self.color.a)
                self.color = picked
                self.onPick(picked)
            }
            self.requestClose?()
            self.bridge.sample()
        }
        let topRow = NSStackView(views: [dot, hexCol, pipette])
        topRow.alignment = .centerY
        topRow.spacing = 10

        rgbaFields = []
        var cols: [NSView] = []
        for (i, name) in ["R", "G", "B", "Alpha"].enumerated() {
            let f = NSTextField(string: "")
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let fmt = NumberFormatter(); fmt.minimum = 0; fmt.maximum = i == 3 ? 100 : 255; fmt.allowsFloats = false
            f.formatter = fmt
            f.widthAnchor.constraint(equalToConstant: 46).isActive = true
            f.onAction { [weak self, weak f] _ in
                guard let self, let f else { return }
                var c = self.color
                let v = Double(f.integerValue)
                switch i {
                case 0: c.r = v / 255
                case 1: c.g = v / 255
                case 2: c.b = v / 255
                default: c.a = v / 100
                }
                self.set(c)
            }
            rgbaFields.append(f)
            cols.append(labeled(f, name))
        }
        let fieldsRow = NSStackView(views: cols)
        fieldsRow.spacing = 8

        let add = NSButton(title: "Add to My Colors", target: nil, action: nil)
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.bezelStyle = .rounded
        add.bezelColor = .controlAccentColor
        add.keyEquivalent = "\r"
        add.onAction { [weak self] _ in self?.addCurrentToCustom() }

        let pane = NSStackView(views: [sb, hueS, alphaS, topRow, fieldsRow, add])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 10
        for v in [sb, hueS, alphaS, add] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        sb.heightAnchor.constraint(equalToConstant: 150).isActive = true
        hueS.heightAnchor.constraint(equalToConstant: 14).isActive = true
        alphaS.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return pane
    }

    private func labeled(_ field: NSView, _ title: String) -> NSView {
        let l = UI.label(title, size: 10)
        let s = NSStackView(views: [field, l])
        s.orientation = .vertical
        s.spacing = 2
        return s
    }

    private func hsbColor() -> RGBAColor {
        UI.rgba(NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)).withAlpha(color.a)
    }

    private func refreshPicker() {
        for (c, sw) in presetSwatches { sw.isChosen = c.isClose(to: color.withAlpha(1)) }
        sbView?.hue = hue
        sbView?.sat = sat
        sbView?.bri = bri
        hueSlider?.value = hue
        alphaSlider?.value = CGFloat(color.a)
        alphaSlider?.color = color.withAlpha(1)
        currentDot?.content = .color(color)
        if let hex = hexField, hex.currentEditor() == nil { hex.stringValue = Self.hex(color) }
        let values = [color.r * 255, color.g * 255, color.b * 255, color.a * 100]
        for (f, v) in zip(rgbaFields, values) where f.currentEditor() == nil { f.integerValue = Int(v.rounded()) }
    }

    private func toggleExpanded() {
        expanded.toggle()
        Defaults[.annotatePaletteExpanded] = expanded
        reload()
    }

    private func addCurrentToCustom() {
        let c = color
        updateCustom { list in
            list.removeAll { $0.isClose(to: c) }
            list.insert(c, at: 0)
        }
    }

    private func updateCustom(_ change: (inout [RGBAColor]) -> Void) {
        var list = Defaults[.annotateCustomColors]
        change(&list)
        Defaults[.annotateCustomColors] = Array(list.prefix(ColorPalette.customSlots))
        reload()
    }

    private func reload() { build() }

    static func hex(_ c: RGBAColor) -> String {
        func b(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }

    static func parseHex(_ s: String) -> RGBAColor? {
        var t = s.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("#") { t.removeFirst() }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return GradientPreset.hex(v)
    }
}

/// Saturation (x) / brightness (y) square with a ring thumb.
@MainActor
final class SaturationBrightnessView: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var sat: CGFloat = 0 { didSet { needsDisplay = true } }
    var bri: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat, CGFloat) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let clip = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
        r.fill()
        NSGradient(colors: [.white, NSColor.white.withAlphaComponent(0)])?.draw(in: r, angle: 0)
        NSGradient(colors: [NSColor.black.withAlphaComponent(0), .black])?.draw(in: r, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        let p = CGPoint(x: r.minX + sat * r.width, y: r.minY + bri * r.height)
        let ring = NSBezierPath(ovalIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
        ring.lineWidth = 3
        NSColor.white.setStroke()
        ring.stroke()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        ring.lineWidth = 0.5
        ring.stroke()
    }

    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let r = bounds.insetBy(dx: 1, dy: 1)
        sat = max(0, min(1, (p.x - r.minX) / r.width))
        bri = max(0, min(1, (p.y - r.minY) / r.height))
        onChange?(sat, bri)
    }
}

/// Capsule slider for hue (rainbow track) or alpha (checkerboard + colour ramp) with a round thumb.
@MainActor
final class ColorSliderView: NSView {
    enum Kind { case hue, alpha }
    let kind: Kind
    var value: CGFloat = 0 { didSet { needsDisplay = true } }
    var color: RGBAColor = .black { didSet { needsDisplay = true } }
    var onChange: ((CGFloat) -> Void)?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        switch kind {
        case .hue:
            let stops = (0...6).map { NSColor(hue: CGFloat($0) / 6, saturation: 1, brightness: 1, alpha: 1) }
            NSGradient(colors: stops)?.draw(in: r, angle: 0)
        case .alpha:
            SwatchButton.drawChecker(r)
            let c = UI.nsColor(color)
            NSGradient(colors: [c.withAlphaComponent(0), c.withAlphaComponent(1)])?.draw(in: r, angle: 0)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        track.lineWidth = 0.5
        track.stroke()
        let d = bounds.height
        let x = r.minX + r.height / 2 + value * (r.width - r.height) - d / 2
        let thumb = NSBezierPath(ovalIn: CGRect(x: x, y: bounds.midY - d / 2, width: d, height: d).insetBy(dx: 1, dy: 1))
        NSColor.white.setFill()
        thumb.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke()
        thumb.lineWidth = 0.5
        thumb.stroke()
    }

    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }

    private func track(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let r = bounds.insetBy(dx: 1, dy: 1)
        value = max(0, min(1, (p.x - r.minX - r.height / 2) / max(1, r.width - r.height)))
        onChange?(value)
    }
}
