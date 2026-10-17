import AppKit
import UniformTypeIdentifiers
import ShotcraftCore

/// Background tool sidebar (CleanShot `ANBackgroundSettings`): fill (none / colour / gradient / wallpaper /
/// image), padding, inset, corner radius, shadow, auto-balance, 9-point alignment, aspect ratio and presets.
@MainActor
final class BackgroundSidebar: NSView {
    static let width: CGFloat = 268

    private let session: EditorSession
    private let bridge: ColorPanelBridge
    private let content = FlippedView()
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    /// Screen used for the desktop wallpaper thumbnail.
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
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 18, right: 14)
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
            self.rebuild()
        }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        rebuild()
    }

    private var thumbnailCache: [String: NSImage] = [:]

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var bg: BackgroundSettings { session.state.background }

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
        s.embeddedImage = embeddedData(for: s.fill)
        session.apply { $0.background = s }
    }

    private func embeddedData(for fill: BackgroundFill) -> Data? {
        switch fill {
        case .image(let path): return WallpaperCache.embeddable(path: path)
        case .desktop:
            guard let s = screenProvider(), let u = NSWorkspace.shared.desktopImageURL(for: s) else { return nil }
            return WallpaperCache.embeddable(path: u.path)
        default: return nil
        }
    }

    private func setFill(_ fill: BackgroundFill) {
        let data = embeddedData(for: fill)
        set("fill") { $0.fill = fill; $0.embeddedImage = data }
    }

    // MARK: Build

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let b = bg

        // Header + presets.
        let title = UI.label("Background", size: 13, color: .labelColor)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let presets = NSPopUpButton(frame: .zero, pullsDown: true)
        presets.controlSize = .small
        presets.toolTip = "Presets"
        presets.menu = presetsMenu()
        let header = NSStackView(views: [title, NSView(), presets])
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true

        // Fill: none / wallpaper / image.
        let tile = CGSize(width: 50, height: 38)
        var row1: [NSView] = []
        let none = SwatchButton(.symbol("nosign"), shape: .tile, size: tile, tooltip: "No background") { [weak self] in self?.setFill(.none) }
        none.isChosen = b.fill.isNone
        row1.append(none)
        let wallpaperImage = screenProvider().flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap { thumbnail($0) }
        let desktop = SwatchButton(.image(wallpaperImage), shape: .tile, size: tile, tooltip: "Desktop wallpaper") { [weak self] in self?.setFill(.desktop) }
        desktop.isChosen = b.fill == .desktop
        row1.append(desktop)
        if case .image(let path) = b.fill {
            let custom = SwatchButton(.image(thumbnail(URL(fileURLWithPath: path))), shape: .tile, size: tile, tooltip: (path as NSString).lastPathComponent) {}
            custom.isChosen = true
            row1.append(custom)
        }
        let choose = SwatchButton(.symbol("photo.badge.plus"), shape: .tile, size: tile, tooltip: "Choose an image…") { [weak self] in self?.chooseImage() }
        row1.append(choose)
        addSection("Wallpaper", rows: [row1])

        // Colours.
        var colorViews: [NSView] = BackgroundColors.all.map { c in
            let sw = SwatchButton(.color(c), shape: .tile, size: CGSize(width: 26, height: 26), tooltip: nil) { [weak self] in self?.setFill(.color(c)) }
            if case .color(let cur) = b.fill { sw.isChosen = cur.isClose(to: c) }
            return sw
        }
        var customColor: RGBAColor = .white
        if case .color(let cur) = b.fill { customColor = cur }
        let picker = SwatchButton(.symbol("paintpalette"), shape: .tile, size: CGSize(width: 26, height: 26), tooltip: "Custom color…") { [weak self] in
            guard let self else { return }
            self.bridge.onColor = { [weak self] c in self?.setFill(.color(c)) }
            self.bridge.showPanel(initial: customColor)
        }
        if case .color(let cur) = b.fill, !BackgroundColors.all.contains(where: { $0.isClose(to: cur) }) { picker.isChosen = true }
        colorViews.append(picker)
        addSection("Colors", rows: chunk(colorViews, 8))

        // Gradients.
        let showAll = Defaults[.annotateShowAllGradients]
        let gradients = showAll ? GradientPreset.all : Array(GradientPreset.all.prefix(GradientPreset.defaultVisibleCount))
        let gViews: [NSView] = gradients.map { g in
            let sw = SwatchButton(.gradient(g), shape: .tile, size: CGSize(width: 38, height: 38), tooltip: g.name) { [weak self] in self?.setFill(.gradient(g.id)) }
            sw.isChosen = b.fill == .gradient(g.id)
            return sw
        }
        addSection("Gradients", rows: chunk(gViews, 6))
        let more = NSButton(title: showAll ? "Show Less" : "Show More", target: nil, action: nil)
        more.bezelStyle = .inline
        more.controlSize = .small
        more.onAction { [weak self] _ in
            Defaults[.annotateShowAllGradients] = !showAll
            self?.rebuild()
        }
        stack.addArrangedSubview(more)

        // Sliders.
        let enabled = b.isActive
        stack.addArrangedSubview(sliderRow("Padding", value: b.padding, range: 0...240, format: { "\(Int($0))" }, enabled: enabled) { [weak self] v in
            self?.set("padding") { $0.padding = v }
        })
        stack.addArrangedSubview(sliderRow("Inset", value: b.inset, range: 0...80, format: { "\(Int($0))" }, enabled: enabled) { [weak self] v in
            self?.set("inset") { $0.inset = v }
        })
        stack.addArrangedSubview(sliderRow("Corners", value: b.cornerRadius, range: 0...48, format: { "\(Int($0))" }, enabled: enabled) { [weak self] v in
            self?.set("corners") { $0.cornerRadius = v }
        })
        stack.addArrangedSubview(sliderRow("Shadow", value: b.shadow, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }, enabled: enabled) { [weak self] v in
            self?.set("shadow") { $0.shadow = v }
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
        stack.addArrangedSubview(balance)

        // Alignment + ratio.
        let align = alignmentGrid(selected: b.alignment, enabled: enabled)
        let ratio = UI.popup(AspectRatio.allCases.map(\.title), selected: AspectRatio.allCases.firstIndex(of: b.aspect) ?? 0,
                             tooltip: "Aspect ratio") { [weak self] i in
            let v = AspectRatio.allCases[i]
            self?.set("aspect") { $0.aspect = v }
        }
        ratio.isEnabled = enabled
        let ratioCol = NSStackView(views: [UI.label("Aspect ratio"), ratio])
        ratioCol.orientation = .vertical
        ratioCol.alignment = .leading
        ratioCol.spacing = 4
        if b.aspect == .custom {
            let fmt = NumberFormatter(); fmt.minimum = 1; fmt.maximum = 1000; fmt.maximumFractionDigits = 2
            let w = NSTextField(string: ""), h = NSTextField(string: "")
            for f in [w, h] { f.controlSize = .small; f.formatter = fmt; f.alignment = .right; f.widthAnchor.constraint(equalToConstant: 40).isActive = true }
            w.doubleValue = b.customAspectWidth; h.doubleValue = b.customAspectHeight
            w.onAction { [weak self] _ in self?.set("aspectW") { $0.customAspectWidth = max(1, w.doubleValue) } }
            h.onAction { [weak self] _ in self?.set("aspectH") { $0.customAspectHeight = max(1, h.doubleValue) } }
            ratioCol.addArrangedSubview(NSStackView(views: [w, UI.label(":"), h]))
        }
        let alignCol = NSStackView(views: [UI.label("Alignment"), align])
        alignCol.orientation = .vertical
        alignCol.alignment = .leading
        alignCol.spacing = 4
        let bottom = NSStackView(views: [alignCol, ratioCol])
        bottom.alignment = .top
        bottom.spacing = 18
        stack.addArrangedSubview(bottom)
    }

    private func addSection(_ title: String, rows: [[NSView]]) {
        stack.addArrangedSubview(UI.label(title.uppercased(), size: 10, color: .tertiaryLabelColor))
        for r in rows {
            let h = NSStackView(views: r)
            h.spacing = 6
            stack.addArrangedSubview(h)
        }
    }

    private func chunk(_ views: [NSView], _ n: Int) -> [[NSView]] {
        stride(from: 0, to: views.count, by: n).map { Array(views[$0..<min($0 + n, views.count)]) }
    }

    private func sliderRow(_ title: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String,
                           enabled: Bool, action: @escaping (Double) -> Void) -> NSView {
        let label = UI.label(title, size: 12, color: .labelColor)
        label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let valueLabel = UI.label(format(value))
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let slider = UI.slider(value: value, min: range.lowerBound, max: range.upperBound, width: 130, tooltip: title) { v in
            valueLabel.stringValue = format(v)
            action(v)
        }
        slider.isEnabled = enabled
        let row = NSStackView(views: [label, slider, valueLabel])
        row.spacing = 6
        return row
    }

    private func alignmentGrid(selected: BackgroundAlignment, enabled: Bool) -> NSView {
        let all = BackgroundAlignment.allCases
        var rows: [[NSView]] = []
        for r in 0..<3 {
            rows.append((0..<3).map { c in
                let a = all[r * 3 + c]
                let b = NSButton(image: NSImage(systemSymbolName: a == selected ? "circle.fill" : "circle", accessibilityDescription: a.rawValue) ?? NSImage(),
                                 target: nil, action: nil)
                b.isBordered = false
                b.contentTintColor = a == selected ? .controlAccentColor : .tertiaryLabelColor
                b.isEnabled = enabled
                b.toolTip = "Align \(a.rawValue)"
                b.widthAnchor.constraint(equalToConstant: 20).isActive = true
                b.heightAnchor.constraint(equalToConstant: 20).isActive = true
                b.onAction { [weak self] _ in self?.set("align") { $0.alignment = a } }
                return b
            })
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 2
        grid.columnSpacing = 2
        return grid
    }

    private func thumbnail(_ url: URL) -> NSImage? {
        if let hit = thumbnailCache[url.path] { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 160,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnailCache[url.path] = img
        return img
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.setFill(.image(url.path))
        }
    }

    // MARK: Presets

    private func presetsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Presets", action: nil, keyEquivalent: "")  // pull-down title
        let presets = Defaults[.annotateBackgroundPresets]
        let current = presets.first { $0.settings.sameLook(as: bg) }
        for p in presets {
            let item = NSMenuItem(title: p.name, key: "", modifiers: []) { [weak self] in
                guard let self else { return }
                var s = p.settings
                if s.embeddedImage == nil { s.embeddedImage = self.embeddedData(for: s.fill) }
                self.session.apply { $0.background = s }
            }
            item.state = p.id == current?.id ? .on : .off
            m.addItem(item)
        }
        if !presets.isEmpty { m.addItem(.separator()) }
        m.addItem(NSMenuItem(title: "Save as New Preset…", key: "", modifiers: []) { [weak self] in self?.savePreset() })
        if let current {
            m.addItem(NSMenuItem(title: "Delete “\(current.name)”", key: "", modifiers: []) { [weak self] in
                Defaults[.annotateBackgroundPresets].removeAll { $0.id == current.id }
                self?.rebuild()
            })
        }
        return m
    }

    private func savePreset() {
        let n = Defaults[.annotateBackgroundPresets].count + 1
        guard let name = Alerts.prompt(title: "Save Background Preset", message: "Name the preset to reuse these background settings.",
                                       defaultValue: "Preset \(n)") else { return }
        var s = bg
        s.embeddedImage = nil
        Defaults[.annotateBackgroundPresets].append(BackgroundPreset(name: name, settings: s))
        rebuild()
    }
}

/// Plain flipped container (top-aligned scroll content).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
