import AppKit
import SuperScreenshotCore

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

    /// Section header: 12 pt semibold, secondary label colour.
    static func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
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

/// A clickable swatch: a colour circle, a gradient / image tile, a text tile, a colour wheel, or an empty / add slot.
@MainActor
final class SwatchButton: NSButton {
    enum Content {
        case color(RGBAColor)
        case gradient(GradientPreset)
        case image(NSImage?)
        /// Rainbow colour wheel (opens a colour picker).
        case wheel
        /// Empty "My Colors" slot: dashed outline (a plus on hover).
        case empty
        /// Dashed "add" tile with a plus.
        case add
        /// A text label ("None").
        case text(String)
    }
    enum Shape { case circle, tile }

    var content: Content { didSet { needsDisplay = true } }
    var shape: Shape
    var isChosen = false { didSet { needsDisplay = true } }
    /// Tile corner radius (content), ignored for circles.
    var cornerRadius: CGFloat = 10
    /// Space between the frame and the content: room for the 2.5 pt selection ring and its gap.
    var contentInset: CGFloat = 4.5
    private var hovering = false { didSet { needsDisplay = true } }
    var onRightClick: (() -> Void)?
    /// Shows a hover ✕ that removes the swatch.
    var onDelete: (() -> Void)?
    /// Enables drag-to-reorder; called with the drop location in window coordinates.
    var onReorder: ((NSPoint) -> Void)?

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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func rightMouseDown(with event: NSEvent) { if let f = onRightClick { f() } else { super.rightMouseDown(with: event) } }

    private var deleteRect: CGRect { CGRect(x: bounds.maxX - 11, y: bounds.maxY - 11, width: 11, height: 11) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let del = onDelete, deleteRect.insetBy(dx: -2, dy: -2).contains(p) { del(); return }
        guard let reorder = onReorder, let window else { super.mouseDown(with: event); return }
        // Click → action; drag beyond a few points → reorder.
        let start = event.locationInWindow
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp {
                performClick(nil)
                return
            }
            if hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 4 {
                NSCursor.closedHand.push()
                defer { NSCursor.pop() }
                while let m = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), m.type != .leftMouseUp {}
                reorder(window.mouseLocationOutsideOfEventStream)
                return
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = contentInset
        let r = bounds.insetBy(dx: inset, dy: inset)
        let radius = max(2, cornerRadius - inset / 2)
        let path: NSBezierPath = shape == .circle ? NSBezierPath(ovalIn: r) : NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let dashed: Bool
        switch content { case .empty, .add: dashed = true; default: dashed = false }
        if dashed {
            path.lineWidth = 1
            path.setLineDash([2.5, 2.5], count: 2, phase: 0)
            (hovering ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
            path.stroke()
            if case .add = content { drawPlus(in: r, size: min(r.width, r.height) * 0.18) } else if hovering { drawPlus(in: r, size: 3) }
            return
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        switch content {
        case .color(let c):
            if c.a < 1 { Self.drawChecker(r) }
            UI.nsColor(c).setFill(); r.fill()
        case .gradient(let g):
            NSGradient(colors: g.colors.map(UI.nsColor))?.draw(in: r, angle: CGFloat(-g.angle))
        case .image(let img):
            NSColor.quaternaryLabelColor.setFill(); r.fill()
            if let img { img.draw(in: aspectFill(img.size, in: r)) }
        case .wheel:
            Self.drawWheel(in: r)
        case .text(let t):
            NSColor.quaternaryLabelColor.setFill(); r.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
            let size = (t as NSString).size(withAttributes: attrs)
            (t as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        case .empty, .add:
            break
        }
        NSGraphicsContext.restoreGraphicsState()
        // Hairline so white swatches are visible in light mode.
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        if isChosen || hovering {
            let ringRect = bounds.insetBy(dx: 1.25, dy: 1.25)
            let ring: NSBezierPath = shape == .circle
                ? NSBezierPath(ovalIn: ringRect)
                : NSBezierPath(roundedRect: ringRect, xRadius: cornerRadius + 1, yRadius: cornerRadius + 1)
            ring.lineWidth = isChosen ? 2.5 : 1
            (isChosen ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
            ring.stroke()
        }
        if hovering, onDelete != nil {
            let d = deleteRect
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: d).fill()
            let x = NSBezierPath()
            let k: CGFloat = 2.5
            x.move(to: CGPoint(x: d.midX - k, y: d.midY - k)); x.line(to: CGPoint(x: d.midX + k, y: d.midY + k))
            x.move(to: CGPoint(x: d.midX - k, y: d.midY + k)); x.line(to: CGPoint(x: d.midX + k, y: d.midY - k))
            x.lineWidth = 1.3
            NSColor.windowBackgroundColor.setStroke()
            x.stroke()
        }
    }

    private func drawPlus(in r: CGRect, size k: CGFloat) {
        let plus = NSBezierPath()
        plus.move(to: CGPoint(x: r.midX - k, y: r.midY)); plus.line(to: CGPoint(x: r.midX + k, y: r.midY))
        plus.move(to: CGPoint(x: r.midX, y: r.midY - k)); plus.line(to: CGPoint(x: r.midX, y: r.midY + k))
        plus.lineWidth = 1.3
        plus.lineCapStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        plus.stroke()
    }

    static func drawChecker(_ r: CGRect) {
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

    /// Hue wheel: 48 wedges around the centre, fading to white in the middle.
    static func drawWheel(in r: CGRect) {
        let c = CGPoint(x: r.midX, y: r.midY), radius = max(r.width, r.height)
        let n = 48
        for i in 0..<n {
            let a0 = CGFloat(i) / CGFloat(n) * 360, a1 = CGFloat(i + 1) / CGFloat(n) * 360 + 0.5
            let p = NSBezierPath()
            p.move(to: c)
            p.appendArc(withCenter: c, radius: radius, startAngle: a0, endAngle: a1)
            p.close()
            NSColor(hue: CGFloat(i) / CGFloat(n), saturation: 0.9, brightness: 1, alpha: 1).setFill()
            p.fill()
        }
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0)])?
            .draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
    }

    private func aspectFill(_ size: NSSize, in r: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return r }
        let s = max(r.width / size.width, r.height / size.height)
        return CGRect(x: r.midX - size.width * s / 2, y: r.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
    }
}

/// Toolbar colour well (CleanShot `annotateColorPicker`): a 16 pt circle in the current colour plus a chevron.
@MainActor
final class ColorWellButton: NSButton {
    var color: RGBAColor { didSet { needsDisplay = true } }

    init(color: RGBAColor, action: @escaping (ColorWellButton) -> Void) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 24))
        bezelStyle = .texturedRounded
        title = ""
        toolTip = "Color"
        setAccessibilityLabel("Color")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        onAction { [weak self] _ in if let self { action(self) } }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let d: CGFloat = 16
        let r = CGRect(x: 8, y: bounds.midY - d / 2, width: d, height: d)
        let p = NSBezierPath(ovalIn: r)
        if color.a < 1 {
            NSGraphicsContext.saveGraphicsState(); p.addClip(); SwatchButton.drawChecker(r); NSGraphicsContext.restoreGraphicsState()
        }
        (isEnabled ? UI.nsColor(color) : UI.nsColor(color).withAlphaComponent(0.35)).setFill()
        p.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        p.lineWidth = 1
        p.stroke()
        drawChevron(in: self, x: r.maxX + 5)
    }
}

/// Draws the small `chevron.down` used by the toolbar's popover buttons.
@MainActor
private func drawChevron(in button: NSButton, x: CGFloat) {
    guard let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) else { return }
    let s = img.size
    let r = CGRect(x: x, y: button.bounds.midY - s.height / 2, width: s.width, height: s.height)
    NSGraphicsContext.saveGraphicsState()
    img.draw(in: r)
    (button.isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).set()
    r.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
}

/// Toolbar tool-style button: a stroke-width preview (or a style glyph) plus a chevron; opens the style popover.
@MainActor
final class StyleButton: NSButton {
    enum Preview: Equatable { case width(CGFloat), symbol(String) }
    var preview: Preview = .symbol("slider.horizontal.3") { didSet { if preview != oldValue { needsDisplay = true } } }

    init(action: @escaping (StyleButton) -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 24))
        bezelStyle = .texturedRounded
        title = ""
        toolTip = "Tool style"
        setAccessibilityLabel("Tool style")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        onAction { [weak self] _ in if let self { action(self) } }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let fg = isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
        let box = CGRect(x: 7, y: bounds.midY - 8, width: 18, height: 16)
        switch preview {
        case .width(let w):
            let p = NSBezierPath()
            p.move(to: CGPoint(x: box.minX + 1, y: box.midY)); p.line(to: CGPoint(x: box.maxX - 1, y: box.midY))
            p.lineWidth = max(1, min(w, 10))
            p.lineCapStyle = .round
            fg.setStroke()
            p.stroke()
        case .symbol(let name):
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
                let s = img.size
                let r = CGRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height)
                NSGraphicsContext.saveGraphicsState()
                img.draw(in: r)
                fg.set()
                r.fill(using: .sourceAtop)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        drawChevron(in: self, x: box.maxX + 4)
    }
}

// MARK: - Colour panel bridge

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
        onColor = nil
        if NSColorPanel.sharedColorPanelExists, Self.active === self {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
    }
}
