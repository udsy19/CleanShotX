import AppKit
import UniformTypeIdentifiers
import SuperScreenshotCore

/// Background tool sidebar (CleanShot `ANBackgroundSettings`), top to bottom: presets, None, Gradients, Wallpapers,
/// Blurred, Plain color, then Padding, Inset + Auto-balance, Shadow + Corners, Alignment + Ratio.
@MainActor
final class BackgroundSidebar: NSView {
    static let width: CGFloat = 240
    private static let gutter: CGFloat = 12
    /// Usable content width.
    private static let inner: CGFloat = width - gutter * 2

    private let session: EditorSession
    private let bridge: ColorPanelBridge
    private let content = FlippedView()
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    /// Thumbnails for the tiles (separate from the renderer's caches so they never evict full-size images).
    private let thumbs = WallpaperCache()
    /// Screen used for the desktop wallpaper.
    var screenProvider: () -> NSScreen? = { NSScreen.main }

    init(session: EditorSession, bridge: ColorPanelBridge) {
        self.session = session
        self.bridge = bridge
        super.init(frame: .zero)
        let fx = NSVisualEffectView()
        fx.material = .sidebar
        fx.blendingMode = .withinWindow
        fx.state = .followsWindowActiveState
        fx.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fx)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.gutter, bottom: 16, right: Self.gutter)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        // A zero-frame NSBox separator assumes horizontal orientation (intrinsic height 1, hugging 750), which would
        // shrink the whole editor window vertically. This one is vertical: let it stretch.
        border.setContentHuggingPriority(.init(1), for: .vertical)
        border.setContentCompressionResistancePriority(.init(1), for: .vertical)
        addSubview(border)

        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: leadingAnchor), fx.trailingAnchor.constraint(equalTo: trailingAnchor),
            fx.topAnchor.constraint(equalTo: topAnchor), fx.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: border.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor), border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor), border.widthAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        session.observe { [weak self] change in
            guard let self, change == .content, !self.isHidden, !session.isInteracting, NSEvent.pressedMouseButtons == 0 else { return }
            self.scheduleRebuild()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        rebuild()
    }

    private var bg: BackgroundSettings { session.state.background }

    private var rebuildScheduled = false

    /// Rebuilds after the current event: the control that triggered the change may still be mid-action.
    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            if !self.isHidden { self.rebuild() }
        }
    }

    private func set(_ key: String, _ change: @escaping (inout BackgroundSettings) -> Void) {
        session.applyCoalescing("bg.\(key)") { change(&$0.background) }
        var remembered = session.state.background
        remembered.embeddedImage = nil
        Defaults[.annotateLastBackground] = remembered
    }

    /// Called when the sidebar opens: make sure a background is visible.
    func ensureBackground() {
        guard !bg.isActive else { return }
        var s = Defaults[.annotateLastBackground] ?? BackgroundSettings()
        if s.fill.isNone { s.fill = .gradient(GradientPreset.all[0].id) }
        s.embeddedImage = WallpaperCache.embeddedData(for: s.fill, screen: screenProvider())
        session.apply { $0.background = s }
    }

    private func setFill(_ fill: BackgroundFill) {
        let data = WallpaperCache.embeddedData(for: fill, screen: screenProvider())
        set("fill") { $0.fill = fill; $0.embeddedImage = data }
    }

    private func apply(_ settings: BackgroundSettings) {
        var s = settings
        if s.embeddedImage == nil { s.embeddedImage = WallpaperCache.embeddedData(for: s.fill, screen: screenProvider()) }
        session.apply { $0.background = s }
    }

    // MARK: Build

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let b = bg

        add(presetRow())

        let none = SwatchButton(.text("None"), shape: .tile, size: CGSize(width: Self.inner, height: 34), tooltip: "No background") { [weak self] in
            self?.setFill(.none)
        }
        none.cornerRadius = 8
        none.contentInset = 3
        none.isChosen = b.fill.isNone
        add(none)

        // Gradients.
        let showAll = Defaults[.annotateShowAllGradients]
        let more = NSButton(title: showAll ? "Show less" : "Show more", target: nil, action: nil)
        more.isBordered = false
        more.font = .systemFont(ofSize: 11)
        more.contentTintColor = .secondaryLabelColor
        more.image = NSImage(systemSymbolName: showAll ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        more.imagePosition = .imageTrailing
        more.onAction { [weak self] _ in
            Defaults[.annotateShowAllGradients] = !showAll
            self?.scheduleRebuild()
        }
        add(header("Gradients", trailing: more))
        let gradients = showAll ? GradientPreset.all : Array(GradientPreset.all.prefix(GradientPreset.defaultVisibleCount))
        add(grid(gradients.map { g in
            let sw = SwatchButton(.gradient(g), shape: .tile, size: CGSize(width: 40, height: 40), tooltip: g.name) { [weak self] in self?.setFill(.gradient(g.id)) }
            sw.isChosen = b.fill == .gradient(g.id)
            return sw
        }, columns: 5, spacing: 4))

        // Wallpapers: desktop, recent custom images, add.
        let tile = CGSize(width: 68, height: 46)
        var walls: [NSView] = []
        let desktopURL = screenProvider().flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let desktop = SwatchButton(.image(desktopURL.flatMap { thumbnail(path: $0.path) }), shape: .tile, size: tile, tooltip: "Desktop wallpaper") { [weak self] in
            self?.setFill(.desktop)
        }
        desktop.isChosen = b.fill == .desktop
        walls.append(desktop)
        var customs = Defaults[.annotateCustomWallpapers].filter { FileManager.default.fileExists(atPath: $0) }
        if case .image(let path) = b.fill, !customs.contains(path) { customs.insert(path, at: 0) }
        for path in customs {
            let sw = SwatchButton(.image(thumbnail(path: path)), shape: .tile, size: tile, tooltip: (path as NSString).lastPathComponent) { [weak self] in
                self?.setFill(.image(path))
            }
            sw.isChosen = b.fill == .image(path)
            sw.onDelete = { [weak self] in
                Defaults[.annotateCustomWallpapers].removeAll { $0 == path }
                self?.scheduleRebuild()
            }
            walls.append(sw)
        }
        walls.append(SwatchButton(.add, shape: .tile, size: tile, tooltip: "Choose an image…") { [weak self] in self?.chooseImage() })
        add(header("Wallpapers"))
        add(grid(walls, columns: 3, spacing: 6))

        // Blurred.
        let blurredWallpaper: NSImage? = desktopURL.flatMap { thumbs.image(path: $0.path, maxPixel: 200) }
            .flatMap { thumbs.blurred($0) }
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        let blurred: [NSView] = BlurredBackground.allCases.map { kind in
            let tileContent: SwatchButton.Content = kind == .wallpaper && blurredWallpaper != nil ? .image(blurredWallpaper) : .gradient(kind.frost)
            let sw = SwatchButton(tileContent, shape: .tile, size: tile, tooltip: kind.title) { [weak self] in self?.setFill(.blurred(kind)) }
            sw.isChosen = b.fill == .blurred(kind)
            return sw
        }
        add(header("Blurred"))
        add(grid(blurred, columns: 3, spacing: 6))

        // Plain colours: saturated + transparent, pastel + custom colour wheel.
        var currentColor: RGBAColor?
        if case .color(let c) = b.fill { currentColor = c }
        func colorSwatch(_ c: RGBAColor, tooltip: String?) -> SwatchButton {
            let sw = SwatchButton(.color(c), shape: .circle, size: CGSize(width: 24, height: 24), tooltip: tooltip) { [weak self] in self?.setFill(.color(c)) }
            sw.contentInset = 3
            sw.isChosen = currentColor?.isClose(to: c) ?? false
            return sw
        }
        var plain: [NSView] = BackgroundColors.saturated.map { colorSwatch($0, tooltip: ColorPalette.name(of: $0)) }
        plain.append(colorSwatch(BackgroundColors.transparent, tooltip: "Transparent"))
        plain += BackgroundColors.pastel.map { colorSwatch($0, tooltip: nil) }
        let wheel = SwatchButton(.wheel, shape: .circle, size: CGSize(width: 24, height: 24), tooltip: "Custom color…") { [weak self] in
            guard let self else { return }
            self.bridge.onColor = { [weak self] c in self?.setFill(.color(c)) }
            self.bridge.showPanel(initial: currentColor ?? .white)
        }
        wheel.contentInset = 3
        let known = BackgroundColors.saturated + BackgroundColors.pastel + [BackgroundColors.transparent]
        wheel.isChosen = currentColor.map { c in !known.contains { $0.isClose(to: c) } } ?? false
        plain.append(wheel)
        add(header("Plain color"))
        add(grid(plain, columns: 9, spacing: 0))

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        add(sep)

        // Layout options (dimmed while there is no background).
        let enabled = b.isActive
        var options: [NSView] = []
        options.append(labeledSlider("Padding", value: b.padding, range: 0...240, width: Self.inner, enabled: enabled) { [weak self] v in
            self?.set("padding") { $0.padding = v }
        })
        let balance = NSButton(checkboxWithTitle: "Auto-balance", target: nil, action: nil)
        balance.controlSize = .small
        balance.toolTip = "Centre the visible part of the screenshot, ignoring transparent margins such as window shadows"
        balance.state = b.autoBalance ? .on : .off
        balance.isEnabled = enabled
        balance.onAction { [weak self] s in
            let on = (s as? NSButton)?.state == .on
            self?.set("balance") { $0.autoBalance = on }
        }
        let inset = labeledSlider("Inset", value: b.inset, range: 0...80, width: 112, enabled: enabled) { [weak self] v in
            self?.set("inset") { $0.inset = v }
        }
        options.append(hstack([inset, balance], spacing: 10, alignment: .bottom))
        let shadow = labeledSlider("Shadow", value: b.shadow * 100, range: 0...100, width: 104, enabled: enabled) { [weak self] v in
            self?.set("shadow") { $0.shadow = v / 100 }
        }
        let corners = labeledSlider("Corners", value: b.cornerRadius, range: 0...48, width: 104, enabled: enabled) { [weak self] v in
            self?.set("corners") { $0.cornerRadius = v }
        }
        options.append(hstack([shadow, corners], spacing: 8, alignment: .top))

        let ratio = UI.popup(AspectRatio.allCases.map(\.title), selected: AspectRatio.allCases.firstIndex(of: b.aspect) ?? 0,
                             tooltip: "Aspect ratio") { [weak self] i in
            let v = AspectRatio.allCases[i]
            self?.set("aspect") { $0.aspect = v }
        }
        ratio.isEnabled = enabled
        let ratioCol = vstack([UI.header("Ratio"), ratio])
        if b.aspect == .custom {
            let fmt = NumberFormatter(); fmt.minimum = 1; fmt.maximum = 1000; fmt.maximumFractionDigits = 2
            let w = NSTextField(string: ""), h = NSTextField(string: "")
            for f in [w, h] {
                f.controlSize = .small; f.formatter = fmt; f.alignment = .right; f.isEnabled = enabled
                f.widthAnchor.constraint(equalToConstant: 40).isActive = true
            }
            w.doubleValue = b.customAspectWidth; h.doubleValue = b.customAspectHeight
            w.onAction { [weak self, weak w] _ in guard let w else { return }; self?.set("aspectW") { $0.customAspectWidth = max(1, w.doubleValue) } }
            h.onAction { [weak self, weak h] _ in guard let h else { return }; self?.set("aspectH") { $0.customAspectHeight = max(1, h.doubleValue) } }
            ratioCol.addArrangedSubview(hstack([w, UI.label(":"), h], spacing: 4, alignment: .centerY))
        }
        let alignCol = vstack([UI.header("Alignment"), alignmentGrid(selected: b.alignment, enabled: enabled)])
        options.append(hstack([alignCol, ratioCol], spacing: 24, alignment: .top))

        for v in options {
            v.alphaValue = enabled ? 1 : 0.45
            if !enabled { v.toolTip = "Choose a background to adjust these options" }
            add(v)
        }
    }

    // MARK: Building blocks

    private func add(_ v: NSView) { stack.addArrangedSubview(v) }

    private func header(_ title: String, trailing: NSView? = nil) -> NSView {
        let label = UI.header(title)
        guard let trailing else { return label }
        let row = hstack([label, NSView(), trailing], spacing: 4, alignment: .centerY)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        return row
    }

    private func hstack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = spacing
        s.alignment = alignment
        return s
    }

    private func vstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    private func grid(_ views: [NSView], columns: Int, spacing: CGFloat) -> NSView {
        let rows = stride(from: 0, to: views.count, by: columns).map { i -> NSView in
            hstack(Array(views[i..<min(i + columns, views.count)]), spacing: spacing, alignment: .centerY)
        }
        let s = vstack(rows)
        s.spacing = spacing
        return s
    }

    /// Header above a small slider; the value shows in the header while it changes.
    private func labeledSlider(_ title: String, value: Double, range: ClosedRange<Double>, width: CGFloat,
                               enabled: Bool, action: @escaping (Double) -> Void) -> NSView {
        let label = UI.header(title)
        let valueLabel = UI.label("\(Int(value.rounded()))", size: 11, color: .tertiaryLabelColor)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let slider = UI.slider(value: value, min: range.lowerBound, max: range.upperBound, width: width, tooltip: title) { [weak valueLabel] v in
            valueLabel?.stringValue = "\(Int(v.rounded()))"
            action(v)
        }
        slider.isEnabled = enabled
        let top = hstack([label, NSView(), valueLabel], spacing: 4, alignment: .firstBaseline)
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalToConstant: width).isActive = true
        return vstack([top, slider])
    }

    private func alignmentGrid(selected: BackgroundAlignment, enabled: Bool) -> NSView {
        let all = BackgroundAlignment.allCases
        let rows: [[NSView]] = (0..<3).map { r in
            (0..<3).map { c in
                let a = all[r * 3 + c]
                let b = AlignmentCell(alignment: a, selected: a == selected)
                b.isEnabled = enabled
                b.onAction { [weak self] _ in self?.set("align") { $0.alignment = a } }
                return b
            }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 2
        grid.columnSpacing = 2
        return grid
    }

    private func thumbnail(path: String) -> NSImage? {
        guard let cg = thumbs.image(path: path, maxPixel: 200) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func chooseImage() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            Defaults[.annotateCustomWallpapers] = RecentProjects.updated(Defaults[.annotateCustomWallpapers], adding: url.path, limit: 5)
            self?.setFill(.image(url.path))
        }
    }

    // MARK: Presets

    private func presetRow() -> NSView {
        let presets = Defaults[.annotateBackgroundPresets]
        let current = presets.first { $0.settings.sameLook(as: bg) }
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.controlSize = .small
        popup.toolTip = "Background presets"
        let m = NSMenu()
        m.addItem(withTitle: current?.name ?? "Presets…", action: nil, keyEquivalent: "")  // pull-down title
        for p in presets {
            let item = NSMenuItem(title: p.name, key: "", modifiers: []) { [weak self] in self?.apply(p.settings) }
            item.image = presetSwatch(p.settings)
            item.state = p.id == current?.id ? .on : .off
            m.addItem(item)
        }
        if !presets.isEmpty { m.addItem(.separator()) }
        let previous = NSMenuItem(title: "Apply Previous Settings", key: "", modifiers: []) { [weak self] in
            guard let self, let last = Defaults[.annotateLastBackground] else { return }
            self.apply(last)
        }
        previous.isEnabled = Defaults[.annotateLastBackground] != nil
        m.addItem(previous)
        let defaultItem = NSMenuItem(title: "Default Preset", action: nil, keyEquivalent: "")
        defaultItem.submenu = defaultPresetMenu(presets)
        m.addItem(defaultItem)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Add New Preset…", key: "", modifiers: []) { [weak self] in self?.savePreset() })
        popup.menu = m

        let trash = UI.symbolButton("trash", tooltip: current.map { "Delete “\($0.name)”" } ?? "Delete preset") { [weak self] in
            guard let current else { return }
            Defaults[.annotateBackgroundPresets].removeAll { $0.id == current.id }
            if Defaults[.annotateDefaultBackgroundPreset] == current.id.uuidString { Defaults[.annotateDefaultBackgroundPreset] = nil }
            self?.scheduleRebuild()
        }
        trash.isEnabled = current != nil
        let plus = UI.symbolButton("plus", tooltip: "Save these settings as a new preset") { [weak self] in self?.savePreset() }
        for b in [trash, plus] { b.controlSize = .small; b.bezelStyle = .texturedRounded }
        let row = hstack([popup, trash, plus], spacing: 4, alignment: .centerY)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func defaultPresetMenu(_ presets: [BackgroundPreset]) -> NSMenu {
        let sub = NSMenu()
        let caption = NSMenuItem(title: "Automatically apply preset to all screenshots:", action: nil, keyEquivalent: "")
        caption.isEnabled = false
        sub.addItem(caption)
        let chosen = Defaults[.annotateDefaultBackgroundPreset]
        for p in presets {
            let item = NSMenuItem(title: p.name, key: "", modifiers: []) { Defaults[.annotateDefaultBackgroundPreset] = p.id.uuidString }
            item.state = chosen == p.id.uuidString ? .on : .off
            sub.addItem(item)
        }
        let none = NSMenuItem(title: "None", key: "", modifiers: []) { Defaults[.annotateDefaultBackgroundPreset] = nil }
        none.state = chosen == nil ? .on : .off
        sub.addItem(none)
        return sub
    }

    /// Small rounded preview of a preset's fill for its menu item.
    private func presetSwatch(_ s: BackgroundSettings) -> NSImage {
        // Capture the renderer, not the sidebar: the image lives in a menu the sidebar owns.
        let renderer = session.renderer
        return NSImage(size: NSSize(width: 18, height: 12), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.clip()
            switch s.fill {
            case .none, .desktop, .image:
                NSColor.tertiaryLabelColor.setFill(); r.fill()
            default:
                renderer.drawFill(s, in: r, ctx: ctx)
            }
            return true
        }
    }

    private func savePreset() {
        let n = Defaults[.annotateBackgroundPresets].count + 1
        guard let name = Alerts.prompt(title: "New Background Preset", message: "Name the preset to reuse these background settings.",
                                       defaultValue: "Preset \(n)") else { return }
        var s = bg
        s.embeddedImage = nil
        Defaults[.annotateBackgroundPresets].append(BackgroundPreset(name: name, settings: s))
        scheduleRebuild()
    }
}

/// One cell of the 3×3 alignment selector: a tiny frame with a block at the aligned position.
@MainActor
private final class AlignmentCell: NSButton {
    private let position: BackgroundAlignment
    private let selected: Bool

    init(alignment: BackgroundAlignment, selected: Bool) {
        self.position = alignment
        self.selected = selected
        super.init(frame: CGRect(x: 0, y: 0, width: 22, height: 18))
        isBordered = false
        title = ""
        toolTip = "Align \(alignment.rawValue)"
        setAccessibilityLabel(toolTip)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let frame = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.quaternaryLabelColor).setFill()
        frame.fill()
        let (fx, fy) = position.factors
        let block = CGSize(width: 8, height: 6)
        let inner = r.insetBy(dx: 3, dy: 3)
        let b = CGRect(x: inner.minX + (inner.width - block.width) * fx, y: inner.minY + (inner.height - block.height) * fy,
                       width: block.width, height: block.height)
        (selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
        NSBezierPath(roundedRect: b, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Plain flipped container (top-aligned scroll content).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
