import AppKit
import ShotcraftCore

// MARK: - Closure actions

private let actionHandlerKey = malloc(1)!

/// Target object that forwards an action to a closure; retained by the sender via an associated object.
final class ActionHandler: NSObject {
    let block: (Any?) -> Void
    init(_ block: @escaping (Any?) -> Void) { self.block = block }
    @objc func fire(_ sender: Any?) { block(sender) }
}

extension NSControl {
    func onAction(_ f: @escaping (Any?) -> Void) {
        let h = ActionHandler(f)
        objc_setAssociatedObject(self, actionHandlerKey, h, .OBJC_ASSOCIATION_RETAIN)
        target = h
        action = #selector(ActionHandler.fire(_:))
    }
}

extension NSMenuItem {
    convenience init(title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], handler: @escaping () -> Void) {
        self.init(title: title, action: nil, keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        let h = ActionHandler { _ in handler() }
        objc_setAssociatedObject(self, actionHandlerKey, h, .OBJC_ASSOCIATION_RETAIN)
        target = h
        action = #selector(ActionHandler.fire(_:))
    }
}

// MARK: - Factories

@MainActor
enum UI {
    static func symbolButton(_ symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(),
                         target: nil, action: nil)
        b.bezelStyle = .texturedRounded
        b.isBordered = true
        b.toolTip = tooltip
        b.setAccessibilityLabel(tooltip)
        b.onAction { _ in action() }
        return b
    }

    static func textButton(_ title: String, symbol: String? = nil, tooltip: String? = nil, action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading }
        b.toolTip = tooltip
        b.onAction { _ in action() }
        return b
    }

    /// Pop-up with string items; `selected` index; calls back with the chosen index.
    static func popup(_ items: [String], selected: Int, tooltip: String, width: CGFloat? = nil, action: @escaping (Int) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.selectItem(at: max(0, min(selected, items.count - 1)))
        p.toolTip = tooltip
        p.controlSize = .small
        p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        p.onAction { s in action((s as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        if let width { p.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return p
    }

    static func slider(value: Double, min: Double, max: Double, width: CGFloat = 110, tooltip: String, action: @escaping (Double) -> Void) -> NSSlider {
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        s.controlSize = .small
        s.isContinuous = true
        s.toolTip = tooltip
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        s.onAction { sender in action((sender as? NSSlider)?.doubleValue ?? value) }
        return s
    }

    static func label(_ text: String, size: CGFloat = NSFont.smallSystemFontSize, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        return l
    }

    static func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    nonisolated static func nsColor(_ c: RGBAColor) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
    nonisolated static func rgba(_ c: NSColor) -> RGBAColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return RGBAColor(r: Double(s.redComponent), g: Double(s.greenComponent), b: Double(s.blueComponent), a: Double(s.alphaComponent))
    }
}

// MARK: - Swatches

/// A clickable swatch: a colour circle, a gradient / image tile, or a symbol tile.
@MainActor
final class SwatchButton: NSButton {
    enum Content {
        case color(RGBAColor)
        case gradient(GradientPreset)
        case image(NSImage?)
        case symbol(String)
    }
    enum Shape { case circle, tile }

    var content: Content { didSet { needsDisplay = true } }
    var shape: Shape
    var isChosen = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    var onRightClick: (() -> Void)?

    init(_ content: Content, shape: Shape, size: CGSize, tooltip: String?, action: @escaping () -> Void) {
        self.content = content
        self.shape = shape
        super.init(frame: CGRect(origin: .zero, size: size))
        isBordered = false
        title = ""
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        onAction { _ in action() }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func rightMouseDown(with event: NSEvent) { if let f = onRightClick { f() } else { super.rightMouseDown(with: event) } }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 3
        let r = bounds.insetBy(dx: inset, dy: inset)
        let path: NSBezierPath = shape == .circle ? NSBezierPath(ovalIn: r) : NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        switch content {
        case .color(let c):
            if c.a < 1 { drawChecker(r) }
            UI.nsColor(c).setFill(); r.fill()
        case .gradient(let g):
            NSGradient(colors: g.colors.map(UI.nsColor))?.draw(in: r, angle: CGFloat(-g.angle))
        case .image(let img):
            NSColor.quaternaryLabelColor.setFill(); r.fill()
            if let img { img.draw(in: aspectFill(img.size, in: r)) }
        case .symbol(let name):
            NSColor.quaternaryLabelColor.setFill(); r.fill()
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: min(r.width, r.height) * 0.42, weight: .medium)) {
                let tinted = img.copy() as! NSImage
                tinted.isTemplate = true
                let s = tinted.size
                let dest = CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height)
                NSColor.secondaryLabelColor.set()
                tinted.draw(in: dest)
                dest.fill(using: .sourceAtop)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        // Hairline so white swatches are visible in light mode.
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        if isChosen || hovering {
            let ring: NSBezierPath = shape == .circle
                ? NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
                : NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            ring.lineWidth = isChosen ? 2 : 1
            (isChosen ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
            ring.stroke()
        }
    }

    private func drawChecker(_ r: CGRect) {
        NSColor.white.setFill(); r.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        let s: CGFloat = 4
        var y = r.minY, row = 0
        while y < r.maxY {
            var x = r.minX + (row % 2 == 0 ? 0 : s)
            while x < r.maxX { NSRect(x: x, y: y, width: s, height: s).fill(); x += s * 2 }
            y += s; row += 1
        }
    }

    private func aspectFill(_ size: NSSize, in r: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return r }
        let s = max(r.width / size.width, r.height / size.height)
        return CGRect(x: r.midX - size.width * s / 2, y: r.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
    }
}

/// Toolbar button that shows the current colour and opens the palette popover.
@MainActor
final class ColorWellButton: NSButton {
    var color: RGBAColor { didSet { needsDisplay = true } }

    init(color: RGBAColor, action: @escaping (ColorWellButton) -> Void) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: 30, height: 24))
        bezelStyle = .texturedRounded
        title = ""
        toolTip = "Color"
        setAccessibilityLabel("Color")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        onAction { [weak self] _ in if let self { action(self) } }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let d: CGFloat = 16
        let r = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let p = NSBezierPath(ovalIn: r)
        UI.nsColor(color).setFill()
        p.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - Colour palette popover

/// Keeps NSColorPanel / NSColorSampler callbacks alive independent of the popover's lifetime.
@MainActor
final class ColorPanelBridge: NSObject {
    var onColor: ((RGBAColor) -> Void)?
    /// The bridge currently set as the shared colour panel's target.
    private static weak var active: ColorPanelBridge?

    func showPanel(initial: RGBAColor) {
        Self.active = self
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = UI.nsColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) { onColor?(UI.rgba(sender.color)) }

    private var sampler: NSColorSampler?

    func sample() {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            guard let color else { return }
            let c = UI.rgba(color)
            Task { @MainActor in
                self?.sampler = nil
                self?.onColor?(c)
            }
        }
    }

    func detach() {
        if NSColorPanel.sharedColorPanelExists, Self.active === self {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
    }
}

/// CleanShot `ANColorPalette`: preset colours (optionally with names), custom colours, opacity and eyedropper.
@MainActor
final class ColorPaletteController: NSViewController {
    private let current: RGBAColor
    private let bridge: ColorPanelBridge
    private let onPick: (RGBAColor) -> Void
    private var opacity: Double

    init(current: RGBAColor, bridge: ColorPanelBridge, onPick: @escaping (RGBAColor) -> Void) {
        self.current = current
        self.bridge = bridge
        self.onPick = onPick
        self.opacity = current.a
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func pick(_ c: RGBAColor) {
        onPick(c.withAlpha(opacity))
    }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let showNames = Defaults[.annotateShowColorNames]
        let presets = ColorPalette.presets
        if showNames {
            let grid = NSGridView()
            grid.rowSpacing = 2
            grid.columnSpacing = 10
            var row: [NSView] = []
            for p in presets {
                let sw = SwatchButton(.color(p.color), shape: .circle, size: CGSize(width: 22, height: 22), tooltip: p.name) { [weak self] in self?.pick(p.color) }
                sw.isChosen = p.color.isClose(to: current.withAlpha(1))
                let name = UI.label(p.name, size: 12, color: .labelColor)
                let item = NSStackView(views: [sw, name])
                item.spacing = 6
                row.append(item)
                if row.count == 2 { grid.addRow(with: row); row = [] }
            }
            if !row.isEmpty { grid.addRow(with: row + [NSView()]) }
            root.addArrangedSubview(grid)
        } else {
            var rows: [NSView] = []
            for chunk in stride(from: 0, to: presets.count, by: 7) {
                let views = presets[chunk..<min(chunk + 7, presets.count)].map { p -> NSView in
                    let sw = SwatchButton(.color(p.color), shape: .circle, size: CGSize(width: 26, height: 26), tooltip: p.name) { [weak self] in self?.pick(p.color) }
                    sw.isChosen = p.color.isClose(to: current.withAlpha(1))
                    return sw
                }
                let r = NSStackView(views: views)
                r.spacing = 4
                rows.append(r)
            }
            rows.forEach { root.addArrangedSubview($0) }
        }

        // Custom colours.
        root.addArrangedSubview(UI.label("Custom"))
        let customRow = NSStackView()
        customRow.spacing = 4
        for (i, c) in Defaults[.annotateCustomColors].enumerated() {
            let sw = SwatchButton(.color(c), shape: .circle, size: CGSize(width: 26, height: 26), tooltip: "Custom color (right-click to remove)") { [weak self] in
                self?.opacity = c.a
                self?.onPick(c)
            }
            sw.isChosen = c.isClose(to: current)
            sw.onRightClick = { [weak self] in
                var list = Defaults[.annotateCustomColors]
                if i < list.count { list.remove(at: i) }
                Defaults[.annotateCustomColors] = list
                self?.reload()
            }
            customRow.addArrangedSubview(sw)
        }
        let add = SwatchButton(.symbol("plus"), shape: .circle, size: CGSize(width: 26, height: 26), tooltip: "Add the current color to custom colors") { [weak self] in
            guard let self else { return }
            var list = Defaults[.annotateCustomColors]
            let c = self.current
            if !list.contains(where: { $0.isClose(to: c) }) { list.append(c) }
            Defaults[.annotateCustomColors] = Array(list.suffix(14))
            self.reload()
        }
        customRow.addArrangedSubview(add)
        root.addArrangedSubview(customRow)

        // Opacity + pipette + system panel.
        let opacitySlider = UI.slider(value: opacity, min: 0.1, max: 1, width: 120, tooltip: "Opacity") { [weak self] v in
            guard let self else { return }
            self.opacity = v
            self.onPick(self.current.withAlpha(v))
        }
        let pipette = UI.symbolButton("eyedropper", tooltip: "Pick a color from the screen") { [weak self] in
            guard let self else { return }
            self.bridge.onColor = { [weak self] c in self?.onPick(c.withAlpha(self?.opacity ?? 1)) }
            self.dismiss(nil)
            self.bridge.sample()
        }
        let wheel = UI.symbolButton("paintpalette", tooltip: "Show Colors") { [weak self] in
            guard let self else { return }
            self.bridge.onColor = { [weak self] c in self?.onPick(c) }
            self.bridge.showPanel(initial: self.current)
        }
        let bottom = NSStackView(views: [UI.label("Opacity"), opacitySlider, pipette, wheel])
        bottom.spacing = 6
        root.addArrangedSubview(bottom)
        view = root
    }

    private func reload() { loadView() }
}
