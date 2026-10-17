import AppKit
import ShotcraftCore

extension Defaults.Keys {
    /// Last ratio picked in the size control (CleanShot: `oneOverlayLastSelectedRatio`).
    static let captureKitLastAspectRatio = Key<String>("capturekit.lastAspectRatio", default: "free")
}

/// Floating glass bars centred below an adjustable selection: the All-In-One mode bar or a confirm bar,
/// followed by the size bar (CleanShot: `OneControlsView`, `OneSizeControl`).
@MainActor
final class SelectionControls {
    /// Horizontal gap between the two bars and vertical gap to the selection.
    static let barGap: CGFloat = 10
    static let selectionGap: CGFloat = 14

    private weak var session: SelectionSession?
    private let sizeBar: SizeControlView
    private let mainBar: NSView

    init(session: SelectionSession) {
        self.session = session
        sizeBar = SizeControlView(session: session, fullscreenToggle: session.config.style == .adjustable)
        mainBar = session.config.style == .allInOne ? AllInOneToolbar(session: session) : ConfirmBar(session: session)
        sizeBar.isHidden = true
        mainBar.isHidden = true
    }

    func layout() {
        guard let s = session, let sel = s.selection, !s.isInteracting, s.mode == .area,
              let host = s.panelsForControls.first(where: { $0.overlayScreenFrame == s.screen(for: sel).frame }) else {
            sizeBar.isHidden = true
            mainBar.isHidden = true
            return
        }
        let view = host.overlayView
        if sizeBar.superview !== view {
            sizeBar.removeFromSuperview(); mainBar.removeFromSuperview()
            view.addSubview(mainBar); view.addSubview(sizeBar)
        }
        var anchor = sel.offsetBy(dx: -host.overlayScreenFrame.minX, dy: -host.overlayScreenFrame.minY)
        anchor = anchor.intersection(view.bounds)
        if anchor.isNull { anchor = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0) }

        sizeBar.update(size: sel.size, aspect: s.aspect, fullscreen: s.isFullscreenSelection)
        let a = mainBar.fittingSize, b = sizeBar.fittingSize
        let group = CGSize(width: a.width + Self.barGap + b.width, height: max(a.height, b.height))
        let g = SelectionGeometry.placeBelow(group, anchor: anchor, bounds: view.bounds, gap: Self.selectionGap)
        let mainFrame = CGRect(x: g.minX, y: g.midY - a.height / 2, width: a.width, height: a.height).integral
        let sizeFrame = CGRect(x: g.minX + a.width + Self.barGap, y: g.midY - b.height / 2, width: b.width, height: b.height).integral
        if mainBar.frame != mainFrame { mainBar.frame = mainFrame }
        if sizeBar.frame != sizeFrame { sizeBar.frame = sizeFrame }
        sizeBar.isHidden = false
        mainBar.isHidden = false
    }

    func tearDown() {
        sizeBar.removeFromSuperview()
        mainBar.removeFromSuperview()
    }
}

// MARK: - Building blocks

/// Dark translucent glass bar (overlay design token): HUD material in dark appearance, 1 px inner highlight,
/// soft drop shadow. Swallows clicks so they do not start a new selection.
@MainActor
class GlassBar: NSView {
    static let height: CGFloat = 52

    let stack = NSStackView()
    private let effect = NSVisualEffectView()
    private let radius: CGFloat

    init(cornerRadius: CGFloat = 14, spacing: CGFloat = 0, insets: NSEdgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)) {
        radius = cornerRadius
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        effect.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Centred vertically: a bar taller than its content (52 pt minimum) never fights the stack.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Bars are positioned by frame; their size is the stack's, never less than the bar height.
    override var fittingSize: NSSize {
        let s = stack.fittingSize
        return NSSize(width: s.width, height: max(s.height, Self.height))
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    /// 1 px vertical divider (white 12%) with an explicit size, so it can never collapse or stretch the bar.
    func separator(height: CGFloat = 24) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 1), v.heightAnchor.constraint(equalToConstant: height)])
        return v
    }

    /// Adds a separator with breathing room on both sides.
    func addSeparator(padding: CGFloat = 4) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(padding, after: last) }
        let sep = separator()
        stack.addArrangedSubview(sep)
        stack.setCustomSpacing(padding, after: sep)
    }
}

/// Borderless button drawn on glass: content at 70% white, a rounded white-12% plate and 100% white on hover.
/// Reacts to the first click even when its panel is not key.
@MainActor
final class GlassButton: NSView {
    private let handler: () -> Void
    private let content: NSView
    private var tintables: [NSView] = []
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { updateAppearance() } }
    private var pressed = false { didSet { updateAppearance() } }
    /// Accent tint (e.g. a locked ratio) instead of white.
    var isHighlighted = false { didSet { updateAppearance() } }

    /// Vertical mode cell: 18 pt symbol over an 11 pt label (All-In-One mode bar).
    convenience init(symbol: String, label: String, tooltip: String, handler: @escaping () -> Void) {
        let icon = GlassButton.symbolView(symbol, pointSize: 18, fallback: label)
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 11, weight: .medium)
        text.alignment = .center
        let column = NSStackView(views: [icon, text])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 3
        self.init(content: column, tintables: [icon, text], size: CGSize(width: 58, height: 44), tooltip: tooltip, handler: handler)
    }

    /// Icon-only (or icon group) button.
    convenience init(symbols: [String], pointSizes: [CGFloat], tooltip: String, size: CGSize, handler: @escaping () -> Void) {
        let icons = zip(symbols, pointSizes).map { GlassButton.symbolView($0, pointSize: $1, fallback: tooltip) }
        let row = NSStackView(views: icons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        self.init(content: row, tintables: icons, size: size, tooltip: tooltip, handler: handler)
    }

    init(content: NSView, tintables: [NSView], size: CGSize, tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        self.content = content
        self.tintables = tintables
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        toolTip = tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height),
            content.centerXAnchor.constraint(equalTo: centerXAnchor), content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func symbolView(_ name: String, pointSize: CGFloat, fallback: String) -> NSView {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let v = NSImageView(image: image)
            v.imageScaling = .scaleNone
            return v
        }
        let t = NSTextField(labelWithString: String(fallback.prefix(1)))
        t.font = .systemFont(ofSize: pointSize, weight: .medium)
        return t
    }

    private func updateAppearance() {
        let active = hovering || pressed
        layer?.backgroundColor = NSColor.white.withAlphaComponent(pressed ? 0.2 : hovering ? 0.12 : 0).cgColor
        let color: NSColor = isHighlighted ? .controlAccentColor : .white.withAlphaComponent(active ? 1 : 0.7)
        for v in tintables {
            (v as? NSImageView)?.contentTintColor = color
            (v as? NSTextField)?.textColor = color
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { handler() }
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { handler(); return true }
}

/// Push button that reacts to the first click even when its panel is not key.
@MainActor
final class FirstMouseButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, prominent: Bool, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        target = self
        action = #selector(fire)
        self.title = title
        bezelStyle = .push
        controlSize = .large
        if prominent { bezelColor = .controlAccentColor }
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func fire() { handler?() }
}

// MARK: - All-In-One mode bar

/// Area · Fullscreen · Window · Scrolling · Timer | OCR | Recording (CleanShot: `oneOverlay*` buttons).
@MainActor
final class AllInOneToolbar: GlassBar {
    init(session: SelectionSession) {
        super.init()
        func button(_ symbol: String, _ label: String, _ tip: String, _ action: @escaping (SelectionSession) -> Void) -> GlassButton {
            GlassButton(symbol: symbol, label: label, tooltip: tip) { [weak session] in session.map(action) }
        }
        let capture = [
            button("viewfinder", "Area", "Capture Area (A)") { $0.confirm() },
            button("display", "Fullscreen", "Capture Fullscreen (F)") { $0.captureFullscreen() },
            button("macwindow", "Window", "Capture Window (Space/W)") { $0.enterWindowMode() },
            button("arrow.down.to.line.compact", "Scrolling", "Scrolling Capture (S)") { $0.perform(.scrolling) },
            button("timer", "Timer", "Self-Timer (T)") { $0.perform(.selfTimer) },
        ]
        capture.forEach { stack.addArrangedSubview($0) }
        addSeparator()
        stack.addArrangedSubview(button("textformat", "OCR", "Capture Text (O)") { $0.perform(.text) })
        addSeparator()
        stack.addArrangedSubview(button("video", "Recording", "Record Screen (R)") { $0.perform(.record) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Confirm bar (adjustable selections for other modules)

@MainActor
final class ConfirmBar: GlassBar {
    init(session: SelectionSession) {
        super.init(spacing: 8, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10))
        let hint = NSTextField(labelWithString: "Drag to adjust · Esc to cancel")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .white.withAlphaComponent(0.7)
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(FirstMouseButton(title: "Cancel", prominent: false) { [weak session] in session?.cancel() })
        stack.addArrangedSubview(FirstMouseButton(title: session.config.confirmTitle, prominent: true) { [weak session] in session?.confirm() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Size bar

/// W x H fields, optional fullscreen toggle (recorder variant) and the ratio menu button
/// (CleanShot: `OneSizeControl` / `VideoSizeControl`, `RatioControlToggleButton`).
@MainActor
final class SizeControlView: GlassBar, NSTextFieldDelegate {
    private weak var session: SelectionSession?
    private let widthField = SizeField()
    private let heightField = SizeField()
    private var ratioButton: GlassButton!
    private var fullscreenButton: GlassButton?

    init(session: SelectionSession, fullscreenToggle: Bool) {
        self.session = session
        super.init(spacing: 6, insets: NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 4))
        for f in [widthField, heightField] { f.delegate = self }
        widthField.setAccessibilityLabel("Width")
        heightField.setAccessibilityLabel("Height")
        let times = NSTextField(labelWithString: "x")
        times.font = .systemFont(ofSize: 13, weight: .medium)
        times.textColor = .white.withAlphaComponent(0.6)

        stack.addArrangedSubview(widthField.plate)
        stack.addArrangedSubview(times)
        stack.addArrangedSubview(heightField.plate)
        if fullscreenToggle {
            let fs = GlassButton(symbols: ["arrow.up.left.and.arrow.down.right"], pointSizes: [14], tooltip: "Fullscreen",
                                 size: CGSize(width: 32, height: 36)) { [weak self] in self?.session?.toggleFullscreenSelection() }
            stack.addArrangedSubview(fs)
            fullscreenButton = fs
        }
        addSeparator()
        ratioButton = GlassButton(symbols: ["crop", "chevron.down"], pointSizes: [15, 9], tooltip: "Aspect ratio",
                                  size: CGSize(width: 46, height: 36)) { [weak self] in self?.openRatioMenu() }
        stack.addArrangedSubview(ratioButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(size: CGSize, aspect: AspectRatio, fullscreen: Bool) {
        for (field, value) in [(widthField, size.width), (heightField, size.height)] where field.currentEditor() == nil {
            let text = String(Int(value.rounded()))
            if field.stringValue != text { field.stringValue = text }
        }
        ratioButton.isHighlighted = aspect != .freeform
        ratioButton.toolTip = aspect == .freeform ? "Aspect ratio" : "Aspect ratio: \(aspect.title)"
        fullscreenButton?.isHighlighted = fullscreen
    }

    private func openRatioMenu() {
        guard let session else { return }
        let menu = NSMenu(title: "Aspect ratio")
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        let header = NSMenuItem(title: "Aspect ratio", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        func add(_ a: AspectRatio) {
            let item = RatioMenuItem(aspect: a) { [weak self] picked in
                Defaults[.captureKitLastAspectRatio] = picked.storageString
                self?.session?.setAspect(picked)
            }
            item.state = session.aspect == a ? .on : .off
            menu.addItem(item)
        }
        AspectRatio.ratios.forEach(add)
        menu.addItem(.separator())
        AspectRatio.sizes.forEach(add)
        let below = CGPoint(x: 0, y: ratioButton.isFlipped ? ratioButton.bounds.maxY + 6 : -6)
        menu.popUp(positioning: nil, at: ratioButton.convert(below, to: self), in: self)
    }

    // MARK: Editing

    private func commit() {
        guard let session, let w = Double(widthField.stringValue), let h = Double(heightField.stringValue), w >= 1, h >= 1 else {
            return
        }
        session.setSize(CGSize(width: w, height: h))
    }

    private func refocusOverlay() {
        guard let overlay = superview as? OverlayView else { return }
        window?.makeFirstResponder(overlay)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commit()
        refocusOverlay()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc while editing reverts the field instead of closing the overlay.
            control.abortEditing()
            if let s = session, let sel = s.selection { update(size: sel.size, aspect: s.aspect, fullscreen: s.isFullscreenSelection) }
            refocusOverlay()
            return true
        }
        return false
    }
}

/// Numeric W / H field: white 15 pt monospaced digits centred on a dark rounded plate.
@MainActor
private final class SizeField: NSTextField {
    /// Rounded background the field sits in (what gets added to the bar).
    let plate = FirstMouseView()

    init() {
        super.init(frame: .zero)
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 1
        f.maximum = 100_000
        f.usesGroupingSeparator = false
        formatter = f
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        textColor = .white
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        translatesAutoresizingMaskIntoConstraints = false

        plate.wantsLayer = true
        plate.layer?.cornerRadius = 6
        plate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        plate.layer?.borderWidth = 0.5
        plate.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(self)
        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: 54), plate.heightAnchor.constraint(equalToConstant: 28),
            leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 3),
            trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -3),
            centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Plain view that takes the first click (a click on a field plate's padding focuses nothing but must not
/// start a selection).
@MainActor
final class FirstMouseView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let field = subviews.first as? NSTextField { window?.makeFirstResponder(field) }
    }
}

/// Menu item carrying an aspect ratio (CleanShot: `RatioMenuItem.ratio`).
@MainActor
private final class RatioMenuItem: NSMenuItem {
    private let aspect: AspectRatio
    private let handler: (AspectRatio) -> Void

    init(aspect: AspectRatio, handler: @escaping (AspectRatio) -> Void) {
        self.aspect = aspect
        self.handler = handler
        super.init(title: aspect.title, action: #selector(pick), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func pick() { handler(aspect) }
}
