import AppKit
import ShotcraftCore

extension Defaults.Keys {
    /// Last ratio picked in the size control (CleanShot: `oneOverlayLastSelectedRatio`).
    static let captureKitLastAspectRatio = Key<String>("capturekit.lastAspectRatio", default: "free")
}

/// Floating controls shown next to an adjustable selection: the size control above it and either the
/// All-In-One toolbar or a confirm bar below it (CleanShot: `OneControlsView`, `OneSizeControl`).
@MainActor
final class SelectionControls {
    private weak var session: SelectionSession?
    private let sizeControl: SizeControlView
    private let bottomBar: NSView

    init(session: SelectionSession) {
        self.session = session
        sizeControl = SizeControlView(session: session)
        if session.config.style == .allInOne {
            bottomBar = AllInOneToolbar(session: session)
        } else {
            bottomBar = ConfirmBar(session: session)
        }
        sizeControl.isHidden = true
        bottomBar.isHidden = true
    }

    func layout() {
        guard let s = session, let sel = s.selection, !s.isInteracting, s.mode == .area,
              let host = s.panelsForControls.first(where: { $0.overlayScreenFrame == s.screen(for: sel).frame }) else {
            sizeControl.isHidden = true
            bottomBar.isHidden = true
            return
        }
        let view = host.overlayView
        if sizeControl.superview !== view {
            sizeControl.removeFromSuperview(); bottomBar.removeFromSuperview()
            view.addSubview(sizeControl); view.addSubview(bottomBar)
        }
        var anchor = sel.offsetBy(dx: -host.overlayScreenFrame.minX, dy: -host.overlayScreenFrame.minY)
        anchor = anchor.intersection(view.bounds)
        if anchor.isNull { anchor = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0) }

        sizeControl.update(size: sel.size, aspect: s.aspect, fullscreen: s.isFullscreenSelection)
        let barFrame = SelectionGeometry.placeBelow(bottomBar.fittingSize, anchor: anchor, bounds: view.bounds).integral
        if bottomBar.frame != barFrame { bottomBar.frame = barFrame }
        let sizeFrame = SelectionGeometry.placeAboveLeading(sizeControl.fittingSize, anchor: anchor, bounds: view.bounds).integral
        if sizeControl.frame != sizeFrame { sizeControl.frame = sizeFrame }
        sizeControl.isHidden = false
        bottomBar.isHidden = false
    }

    func tearDown() {
        sizeControl.removeFromSuperview()
        bottomBar.removeFromSuperview()
    }
}

// MARK: - Building blocks

/// Dark HUD container that swallows clicks so they do not start a new selection.
@MainActor
class HUDBox: NSVisualEffectView {
    let stack = NSStackView()

    init(spacing: CGFloat = 4, insets: NSEdgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var fittingSize: NSSize { stack.fittingSize }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 20).isActive = true
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }
}

/// Button that reacts to the first click even when its panel is not key.
@MainActor
final class FirstMouseButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(symbol: String, tooltip: String, prominent: Bool = false, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        target = self
        action = #selector(fire)
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        if image == nil { title = String(tooltip.prefix(1)); imagePosition = .noImage }
        contentTintColor = prominent ? .controlAccentColor : .white
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    convenience init(title: String, prominent: Bool, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        target = self
        action = #selector(fire)
        self.title = title
        bezelStyle = .rounded
        controlSize = .regular
        if prominent { bezelColor = .controlAccentColor }
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func fire() { handler?() }
}

// MARK: - All-In-One toolbar

@MainActor
final class AllInOneToolbar: HUDBox {
    init(session: SelectionSession) {
        super.init(spacing: 2)
        let groups: [[NSView]] = [
            [FirstMouseButton(symbol: "camera.viewfinder", tooltip: "Capture Area (A / ↩)", prominent: true) { [weak session] in session?.confirm() },
             FirstMouseButton(symbol: "display", tooltip: "Capture Fullscreen (F)") { [weak session] in session?.captureFullscreen() },
             FirstMouseButton(symbol: "macwindow", tooltip: "Capture Window (Space/W)") { [weak session] in session?.enterWindowMode() },
             FirstMouseButton(symbol: "scroll", tooltip: "Scrolling Capture (S)") { [weak session] in session?.perform(.scrolling) },
             FirstMouseButton(symbol: "text.viewfinder", tooltip: "Capture Text (O)") { [weak session] in session?.perform(.text) }],
            [FirstMouseButton(symbol: "record.circle", tooltip: "Record Screen (R)") { [weak session] in session?.perform(.record) },
             FirstMouseButton(symbol: "photo.on.rectangle.angled", tooltip: "Record GIF (G)") { [weak session] in session?.perform(.gif) }],
            [FirstMouseButton(symbol: "timer", tooltip: "Self-Timer (T)") { [weak session] in session?.perform(.selfTimer) }],
            [FirstMouseButton(symbol: "xmark", tooltip: "Close (Esc)") { [weak session] in session?.cancel() }],
        ]
        for (i, group) in groups.enumerated() {
            if i > 0 { stack.addArrangedSubview(separator()) }
            group.forEach { stack.addArrangedSubview($0) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Confirm bar (adjustable selections for other modules)

@MainActor
final class ConfirmBar: HUDBox {
    init(session: SelectionSession) {
        super.init(spacing: 8, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
        let hint = NSTextField(labelWithString: "Drag to adjust · ↩ to confirm · Esc to cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(FirstMouseButton(title: "Cancel", prominent: false) { [weak session] in session?.cancel() })
        stack.addArrangedSubview(FirstMouseButton(title: "\(session.config.confirmTitle) ↩", prominent: true) { [weak session] in session?.confirm() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - Size control

/// W × H fields, aspect-ratio menu and fullscreen toggle (CleanShot: `OneSizeControl` / `VideoSizeControl`).
@MainActor
final class SizeControlView: HUDBox, NSTextFieldDelegate {
    private weak var session: SelectionSession?
    private let widthField = SizeField()
    private let heightField = SizeField()
    private var ratioButton: NSButton!
    private var fullscreenButton: FirstMouseButton!

    init(session: SelectionSession) {
        self.session = session
        super.init(spacing: 4)
        for f in [widthField, heightField] { f.delegate = self }
        widthField.setAccessibilityLabel("Width")
        heightField.setAccessibilityLabel("Height")
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor

        let ratio = FirstMouseButton(title: "Freeform", prominent: false) { [weak self] in self?.openRatioMenu() }
        ratio.bezelStyle = .recessed
        ratio.isBordered = false
        ratio.font = .systemFont(ofSize: 12, weight: .medium)
        ratio.contentTintColor = .white
        ratio.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        ratio.imagePosition = .imageTrailing
        ratio.toolTip = "Aspect ratio"
        ratioButton = ratio

        fullscreenButton = FirstMouseButton(symbol: "arrow.up.left.and.arrow.down.right", tooltip: "Fullscreen") { [weak self] in
            self?.session?.toggleFullscreenSelection()
        }
        stack.addArrangedSubview(widthField)
        stack.addArrangedSubview(times)
        stack.addArrangedSubview(heightField)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(ratio)
        stack.addArrangedSubview(fullscreenButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(size: CGSize, aspect: AspectRatio, fullscreen: Bool) {
        for (field, value) in [(widthField, size.width), (heightField, size.height)] where field.currentEditor() == nil {
            let text = String(Int(value.rounded()))
            if field.stringValue != text { field.stringValue = text }
        }
        if ratioButton.title != aspect.title { ratioButton.title = aspect.title }
        fullscreenButton.contentTintColor = fullscreen ? .controlAccentColor : .white
    }

    private func openRatioMenu() {
        guard let session else { return }
        let menu = NSMenu(title: "Aspect ratio")
        menu.autoenablesItems = false
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
        let below = CGPoint(x: 0, y: ratioButton.isFlipped ? ratioButton.bounds.maxY + 4 : -4)
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
            if let s = session?.selection { update(size: s.size, aspect: session?.aspect ?? .freeform, fullscreen: false) }
            refocusOverlay()
            return true
        }
        return false
    }
}

/// Numeric field used for W / H.
@MainActor
private final class SizeField: NSTextField {
    init() {
        super.init(frame: .zero)
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 1
        f.maximum = 100_000
        f.usesGroupingSeparator = false
        formatter = f
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        bezelStyle = .roundedBezel
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 58).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
