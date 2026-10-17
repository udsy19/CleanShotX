import AppKit
import UniformTypeIdentifiers
import ShotcraftCore

/// Window that routes ⌘-shortcuts to the editor (the app has no main menu while it is an accessory app).
final class EditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps the document centred when it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = f.minX - (r.width - f.width) / 2 }
        if r.height > f.height { r.origin.y = f.minY - (r.height - f.height) / 2 }
        return r
    }
}

/// One Annotate editor window (CleanShot `Annotate: NSWindowController`).
@MainActor
final class AnnotateEditorController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum Origin {
        /// A capture or image file: Done writes the flattened image back to `media.url`.
        case media
        /// An image from the clipboard: Done creates a new file and shows it in Quick Access.
        case clipboard
        /// A `.shotcraft` project: Done saves the project.
        case project
    }

    let session: EditorSession
    let origin: Origin
    private(set) var media: CapturedMedia?
    private(set) var projectURL: URL?
    private let createdAt: Date
    var onClose: ((AnnotateEditorController) -> Void)?

    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private let bridge = ColorPanelBridge()
    private let stylePanel: ToolStylePanel
    private let cropBar: CropBar
    private var sidebar: BackgroundSidebar!
    /// Scroll view leading edge: to the window edge, or to the background sidebar when it is shown.
    private var scrollLeadingToRoot: NSLayoutConstraint!
    private var scrollLeadingToSidebar: NSLayoutConstraint!
    private var popover: NSPopover?

    // Toolbar (CleanShot X 5.0, left → right): Crop, Add image, Background · tools · colour, style, lock · Save, Done.
    private let cropChip = NSButton()
    private let addChip = NSPopUpButton(frame: .zero, pullsDown: true)
    private let backgroundChip = NSButton()
    private let toolControl = NSSegmentedControl()
    private var colorWell: ColorWellButton!
    private var styleButton: StyleButton!
    private let lockButton = NSButton()
    private let saveButton = NSButton()
    private let doneButton = NSButton()
    private let cancelCropButton = NSButton()
    private let applyCropButton = NSButton()
    private var toolGroup: NSStackView!
    private var styleGroup: NSStackView!
    private var actionGroup: NSStackView!
    private var leadingGroup: NSStackView!

    // Bottom bar
    private var zoomButton: NSPopUpButton!
    private var sizeLabel: NSTextField!
    private var dragHandle: DragHandleView!
    private var closeConfirmed = false
    private var didInitialZoom = false

    private static let objectsPasteboardType = NSPasteboard.PasteboardType("com.udsy.shotcraft.annotations")
    private static let toolbarHeight: CGFloat = 52
    private static let bottomBarHeight: CGFloat = 40

    init(state: CanvasState, origin: Origin, media: CapturedMedia?, projectURL: URL?, createdAt: Date = Date()) {
        self.session = EditorSession(state: state)
        self.origin = origin
        self.media = media
        self.projectURL = projectURL
        self.createdAt = createdAt
        self.canvas = CanvasView(session: session)
        self.stylePanel = ToolStylePanel(session: session, canvas: canvas)
        self.cropBar = CropBar(session: session, canvas: canvas)
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.keyHandler = { [weak self] e in self?.handleKeyEquivalent(e) ?? false }
        window.titleVisibility = .hidden
        buildToolbarViews()
        buildToolbar(window)
        buildContent(window)
        session.observe { [weak self] change in self?.sessionChanged(change) }
        session.renderer.desktopWallpaperPath = { [weak window] in
            guard let s = window?.screen ?? NSScreen.main, let u = NSWorkspace.shared.desktopImageURL(for: s) else { return nil }
            return u.path
        }
        updateTitle()
        updateSizeLabel()
        updateToolbarState()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: - Building

    private enum ItemID {
        static let leading = NSToolbarItem.Identifier("annotate.leading")
        static let tools = NSToolbarItem.Identifier("annotate.tools")
        static let style = NSToolbarItem.Identifier("annotate.style")
        static let actions = NSToolbarItem.Identifier("annotate.actions")
    }

    private func buildToolbarViews() {
        func chip(_ b: NSButton, symbol: String, tooltip: String) {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            b.imagePosition = .imageOnly
            b.title = ""
            b.bezelStyle = .texturedRounded
            b.toolTip = tooltip
            b.setAccessibilityLabel(tooltip)
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        chip(cropChip, symbol: AnnotateTool.crop.symbol, tooltip: "Crop & Resize (K)")
        cropChip.setButtonType(.pushOnPushOff)
        cropChip.onAction { [weak self] _ in
            guard let self else { return }
            if self.canvas.isCropping { self.canvas.cancelCrop() } else { self.canvas.startCrop() }
            self.focusCanvas()
        }

        addChip.bezelStyle = .texturedRounded
        addChip.toolTip = "Add an image"
        (addChip.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        addChip.imagePosition = .imageOnly
        let addMenu = NSMenu()
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "Add image")
        addMenu.addItem(title)
        addMenu.addItem(NSMenuItem(title: "Add New Screenshot", key: "i", modifiers: [.command, .shift]) { [weak self] in self?.addNewScreenshot() })
        addMenu.addItem(NSMenuItem(title: "Add Screenshot From File…", key: "i") { [weak self] in self?.addImageFromFile() })
        addMenu.addItem(NSMenuItem(title: "Paste From Clipboard", key: "", modifiers: []) { [weak self] in self?.addImageFromClipboard() })
        addChip.menu = addMenu
        addChip.widthAnchor.constraint(equalToConstant: 34).isActive = true

        chip(backgroundChip, symbol: "photo.artframe", tooltip: "Background Tool (B)")
        backgroundChip.setButtonType(.pushOnPushOff)
        backgroundChip.onAction { [weak self] _ in self?.toggleBackgroundTool(); self?.focusCanvas() }

        leadingGroup = NSStackView(views: [cropChip, addChip, backgroundChip])
        leadingGroup.spacing = 6

        let tools = AnnotateTool.toolbarTools
        toolControl.segmentCount = tools.count
        toolControl.trackingMode = .selectOne
        toolControl.segmentStyle = .rounded
        toolControl.selectedSegmentBezelColor = .controlAccentColor
        for (i, t) in tools.enumerated() {
            let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            toolControl.setImage(img, forSegment: i)
            toolControl.setImageScaling(.scaleProportionallyDown, forSegment: i)
            toolControl.setToolTip("\(t.title) (\(String(t.key).uppercased()))", forSegment: i)
            toolControl.setWidth(28, forSegment: i)
        }
        toolControl.onAction { [weak self] _ in
            guard let self else { return }
            let i = self.toolControl.selectedSegment
            guard tools.indices.contains(i) else { return }
            self.session.tool = tools[i]
            self.focusCanvas()
        }
        cropBar.isHidden = true
        toolGroup = NSStackView(views: [toolControl, cropBar])
        toolGroup.spacing = 0

        colorWell = ColorWellButton(color: .black) { [weak self] b in self?.showPalette(from: b) }
        styleButton = StyleButton { [weak self] b in self?.showStylePanel(from: b) }
        lockButton.setButtonType(.pushOnPushOff)
        lockButton.bezelStyle = .texturedRounded
        lockButton.imagePosition = .imageOnly
        lockButton.title = ""
        lockButton.toolTip = "Keep the tool active after drawing"
        lockButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        Self.setLock(lockButton, on: Defaults[.annotateToolLocked])
        lockButton.onAction { [weak self] s in
            guard let self, let b = s as? NSButton else { return }
            Defaults[.annotateToolLocked] = b.state == .on
            Self.setLock(b, on: b.state == .on)
            self.focusCanvas()
        }
        styleGroup = NSStackView(views: [colorWell, styleButton, lockButton])
        styleGroup.spacing = 6

        func textButton(_ b: NSButton, _ title: String, prominent: Bool, action: @escaping () -> Void) {
            b.title = title
            b.bezelStyle = .rounded
            b.controlSize = .regular
            if prominent { b.bezelColor = .controlAccentColor }
            b.onAction { _ in action() }
        }
        let ask = Defaults[.annotateSaveBehavior] == .askForDestination
        textButton(saveButton, ask ? "Save as…" : "Save", prominent: false) { [weak self] in self?.save() }
        saveButton.toolTip = ask ? "Save to a location you choose (⇧⌘S for other formats)" : "Save to the export location (⇧⌘S: Save As…)"
        textButton(doneButton, "Done", prominent: true) { [weak self] in self?.done() }
        doneButton.keyEquivalent = "\r"
        doneButton.keyEquivalentModifierMask = .command
        doneButton.toolTip = "Apply changes and close (⌘S)"
        textButton(cancelCropButton, "Cancel", prominent: false) { [weak self] in self?.canvas.cancelCrop() }
        cancelCropButton.toolTip = "Cancel cropping (Esc)"
        textButton(applyCropButton, "Crop", prominent: true) { [weak self] in self?.canvas.applyCrop() }
        applyCropButton.toolTip = "Apply the crop (Return)"
        cancelCropButton.isHidden = true
        applyCropButton.isHidden = true
        actionGroup = NSStackView(views: [saveButton, doneButton, cancelCropButton, applyCropButton])
        actionGroup.spacing = 8
    }

    /// Toggle chips show their "on" state in the accent colour.
    private static func setChip(_ b: NSButton, on: Bool) {
        b.state = on ? .on : .off
        b.contentTintColor = on ? .controlAccentColor : nil
    }

    /// Draw lock: closed padlock while the tool stays active after drawing.
    private static func setLock(_ b: NSButton, on: Bool) {
        setChip(b, on: on)
        b.image = NSImage(systemSymbolName: on ? "lock.fill" : "lock.open", accessibilityDescription: on ? "Draw lock on" : "Draw lock off")
    }

    private func buildToolbar(_ window: NSWindow) {
        let tb = NSToolbar(identifier: "ShotcraftAnnotateToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        window.toolbar = tb
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.leading, ItemID.tools, ItemID.style, .flexibleSpace, ItemID.actions]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case ItemID.leading: item.view = leadingGroup; item.label = "Image"
        case ItemID.tools: item.view = toolGroup; item.label = "Tools"; item.visibilityPriority = .high
        case ItemID.style: item.view = styleGroup; item.label = "Style"
        case ItemID.actions: item.view = actionGroup; item.label = "Done"; item.visibilityPriority = .user
        default: return nil
        }
        return item
    }

    private func buildContent(_ window: NSWindow) {
        let root = NSView()
        window.contentView = root

        sidebar = BackgroundSidebar(session: session, bridge: bridge)
        sidebar.screenProvider = { [weak window] in window?.screen ?? NSScreen.main }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.isHidden = true

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        // Neutral canvas: very light grey in light mode, #1E1E1E in dark mode.
        scrollView.backgroundColor = NSColor(name: "annotateCanvas") { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
                                                               : NSColor(srgbRed: 0.953, green: 0.953, blue: 0.957, alpha: 1)
        }
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        canvas.onDropFiles = { [weak self] urls, p in self?.handleDrop(urls, at: p) }
        canvas.contextMenuProvider = { [weak self] in self?.contextMenu() }
        canvas.extraKeyHandler = { [weak self] ch in
            if ch == "b" { self?.toggleBackgroundTool(); return true }
            return false
        }

        let bottom = buildBottomBar()
        let bottomLine = NSBox(); bottomLine.boxType = .separator; bottomLine.translatesAutoresizingMaskIntoConstraints = false

        [sidebar, scrollView, bottomLine, bottom].forEach { root.addSubview($0) }
        scrollLeadingToRoot = scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        scrollLeadingToSidebar = scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollLeadingToRoot,

            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            // Never let content hugging collapse the canvas (and the window with it).
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    /// Bottom bar (CleanShot 4.8+): zoom popup at the left, "Drag me" in the centre, Share / Pin / Copy / Upload at the right.
    private func buildBottomBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false

        zoomButton = NSPopUpButton(frame: .zero, pullsDown: true)
        zoomButton.bezelStyle = .texturedRounded
        zoomButton.controlSize = .small
        zoomButton.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        zoomButton.toolTip = "Zoom (⌘+ / ⌘− / ⌘0 fit / ⌘1 actual size)"
        let zm = NSMenu()
        zm.addItem(NSMenuItem(title: "100%", action: nil, keyEquivalent: ""))
        zm.addItem(NSMenuItem(title: "Zoom In", key: "+") { [weak self] in self?.zoom(by: 1.25) })
        zm.addItem(NSMenuItem(title: "Zoom Out", key: "-") { [weak self] in self?.zoom(by: 0.8) })
        zm.addItem(NSMenuItem(title: "Zoom to Fit", key: "0") { [weak self] in self?.zoomToFit() })
        zm.addItem(NSMenuItem(title: "Actual Size", key: "1") { [weak self] in self?.setZoom(1) })
        zm.addItem(.separator())
        for p in [25, 50, 200, 400] {
            zm.addItem(NSMenuItem(title: "\(p)%", key: "", modifiers: []) { [weak self] in self?.setZoom(CGFloat(p) / 100) })
        }
        zoomButton.menu = zm
        zoomButton.widthAnchor.constraint(equalToConstant: 68).isActive = true

        sizeLabel = UI.label("", size: 11, color: .tertiaryLabelColor)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dragHandle = DragHandleView()
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.fileProvider = { [weak self] in self?.writeTemporaryFile() }

        func icon(_ symbol: String, _ tooltip: String, _ action: @escaping (NSButton) -> Void) -> NSButton {
            let b = UI.symbolButton(symbol, tooltip: tooltip) {}
            b.onAction { [weak b] _ in if let b { action(b) } }
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        let share = icon("square.and.arrow.up", "Share") { [weak self] b in self?.share(from: b) }
        let pin = icon("pin.fill", "Pin to the screen") { [weak self] _ in self?.pinAndClose() }
        let copy = icon("doc.on.doc.fill", "Copy and close (⌥: copy without closing)") { [weak self] _ in
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true { self?.copyImage() } else { self?.copyAndClose() }
        }
        let upload = icon("icloud.and.arrow.up.fill", "Upload to the cloud") { [weak self] _ in self?.uploadAndClose() }
        upload.isEnabled = Services.upload != nil

        let left = NSStackView(views: [zoomButton, sizeLabel])
        left.spacing = 10
        let right = NSStackView(views: [share, pin, copy, upload])
        right.spacing = 8
        for s in [left, right] { s.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(s) }
        bar.addSubview(dragHandle)
        let centered = dragHandle.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            dragHandle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            centered,
            dragHandle.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: dragHandle.trailingAnchor, constant: 12),
        ])
        return bar
    }

    // MARK: - Showing

    /// Sizes the window around the image (≤ 90 % of the screen), zooms to fit and focuses the canvas.
    func present() {
        guard let window else { return }
        let screen = NSScreen.active.visibleFrame
        let out = canvas.frame.size
        let chrome = Self.toolbarHeight + Self.bottomBarHeight + 1
        updateMinimumSize()
        let w = min(max(out.width + 40, window.minSize.width, 860), screen.width * 0.9)
        let h = min(max(out.height + chrome + 30, 540), screen.height * 0.9)
        window.setFrame(NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h), display: false)
        window.level = Defaults[.annotateAlwaysOnTop] ? .floating : .normal
        if Defaults[.annotateRememberBackgroundTool] && Defaults[.annotateBackgroundToolOpen] { setBackgroundTool(visible: true, remember: false) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        zoomToFit()
        didInitialZoom = true
        focusCanvas()
    }

    /// Minimum width that keeps every toolbar item visible (normal and crop mode).
    private func updateMinimumSize() {
        guard let window else { return }
        let tools = max(toolControl.fittingSize.width, cropBar.fittingSize.width)
        let actions = max(saveButton.fittingSize.width + doneButton.fittingSize.width,
                          cancelCropButton.fittingSize.width + applyCropButton.fittingSize.width) + 8
        // Traffic lights + item spacing + flexible-space minimum.
        let width = 86 + leadingGroup.fittingSize.width + tools + styleGroup.fittingSize.width + actions + 5 * 10 + 24
        window.minSize = NSSize(width: max(640, ceil(width)), height: 420)
    }

    private func focusCanvas() {
        guard canvas.editingID == nil else { return }
        window?.makeFirstResponder(canvas)
    }

    // MARK: - Session changes

    private func sessionChanged(_ change: EditorSession.Change) {
        switch change {
        case .tool:
            updateCropMode()
            updateToolbarState()
        case .selection, .style:
            updateToolbarState()
        case .content:
            updateTitle()
            updateSizeLabel()
            updateToolbarState()
        }
    }

    /// Crop mode swaps the tool group for the crop bar and Save / Done for Cancel / Crop.
    private func updateCropMode() {
        let cropping = canvas.isCropping
        guard cropBar.isHidden == cropping else { return }
        popover?.close()
        toolControl.isHidden = cropping
        cropBar.isHidden = !cropping
        styleGroup.arrangedSubviews.forEach { $0.isHidden = cropping }
        saveButton.isHidden = cropping
        doneButton.isHidden = cropping
        cancelCropButton.isHidden = !cropping
        applyCropButton.isHidden = !cropping
        Self.setChip(cropChip, on: cropping)
        if cropping { cropBar.reset() }
    }

    /// Selected tool, colour well and style-button preview for the current tool / selection.
    private func updateToolbarState() {
        if let i = AnnotateTool.toolbarTools.firstIndex(of: session.tool) { toolControl.selectedSegment = i } else { toolControl.selectedSegment = -1 }
        let target = session.styleTarget
        let sample = session.styleSample
        let style = session.style(for: target)
        let imagesOnly = !session.selection.isEmpty && session.selectedObjects.allSatisfy { $0.kind == .image }
        let colorable: Set<AnnotateTool> = [.rectangle, .filledRectangle, .ellipse, .line, .arrow, .text, .pen, .highlighter, .counter]
        colorWell.isEnabled = !imagesOnly && colorable.contains(target)
        colorWell.color = sample?.color ?? style.color
        styleButton.isEnabled = imagesOnly || (target != .select && target != .crop)
        switch target {
        case .rectangle, .ellipse, .line, .arrow, .pen:
            styleButton.preview = .width(sample?.lineWidth ?? style.lineWidth)
        case .highlighter where (sample?.highlightShape ?? style.highlightShape) == .freehand:
            styleButton.preview = .width(sample?.lineWidth ?? style.lineWidth)
        case .text:
            styleButton.preview = .symbol("textformat")
        default:
            styleButton.preview = .symbol("slider.horizontal.3")
        }
        styleButton.toolTip = imagesOnly ? "Image style" : "\(target.title) style"
    }

    // MARK: - Popovers

    private func showPopover(_ vc: NSViewController, from view: NSView) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        popover = p
    }

    private func showPalette(from button: ColorWellButton) {
        let vc = ColorPaletteController(current: button.color, bridge: bridge) { [weak self] c in
            guard let self else { return }
            self.session.restyle(coalesce: "color", style: { $0.color = c }, object: { $0.color = c })
            self.canvas.refreshTextEditor()
        }
        vc.requestClose = { [weak self] in self?.popover?.close() }
        showPopover(vc, from: button)
    }

    private func showStylePanel(from button: StyleButton) {
        stylePanel.rebuild()
        showPopover(stylePanel, from: button)
    }

    private var baseName: String {
        if let m = media { return m.url.deletingPathExtension().lastPathComponent }
        if let p = projectURL { return p.deletingPathExtension().lastPathComponent }
        return untitledName
    }

    /// Name for clipboard sessions, rendered once so random/counter tokens stay stable.
    private lazy var untitledName = FileNameTemplate.render(Defaults[.fileNameTemplate], kind: CaptureMode.imported.fileNameKind)

    private func updateTitle() {
        guard let window else { return }
        window.title = baseName
        if let m = media { window.representedURL = m.url } else if let p = projectURL { window.representedURL = p }
        window.isDocumentEdited = session.isDirty
    }

    private func updateSizeLabel() {
        let l = session.exportLayout()
        let sc = session.state.scale
        let w = Int((l.outputSize.width * sc).rounded()), h = Int((l.outputSize.height * sc).rounded())
        sizeLabel?.stringValue = "\(w) × \(h) px"
    }

    @objc private func viewportChanged() {
        let pct = Int((scrollView.magnification * 100).rounded())
        zoomButton?.item(at: 0)?.title = "\(pct)%"
        canvas.window?.invalidateCursorRects(for: canvas)
    }

    // MARK: - Zoom

    func setZoom(_ m: CGFloat, centeredAt p: CGPoint? = nil) {
        let clip = scrollView.contentView
        let center = p ?? CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        scrollView.setMagnification(max(scrollView.minMagnification, min(scrollView.maxMagnification, m)), centeredAt: center)
        viewportChanged()
        canvas.needsDisplay = true
    }

    func zoom(by f: CGFloat) { setZoom(scrollView.magnification * f) }

    func zoomToFit() {
        let avail = scrollView.contentView.frame.size
        let doc = canvas.frame.size
        guard doc.width > 0, doc.height > 0, avail.width > 0 else { return }
        let m = min(1, avail.width / doc.width, avail.height / doc.height)
        scrollView.magnification = max(scrollView.minMagnification, m)
        let clip = scrollView.contentView
        let centered = NSPoint(x: (doc.width - clip.bounds.width) / 2, y: (doc.height - clip.bounds.height) / 2)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: centered, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        viewportChanged()
    }

    // MARK: - Background tool

    private var backgroundToolVisible: Bool { !sidebar.isHidden }

    func toggleBackgroundTool() { setBackgroundTool(visible: !backgroundToolVisible, remember: true) }

    private func setBackgroundTool(visible: Bool, remember: Bool) {
        if visible { sidebar.ensureBackground() }
        sidebar.isHidden = !visible
        // Deactivate before activating so the two leading constraints never conflict.
        if visible { scrollLeadingToRoot.isActive = false; scrollLeadingToSidebar.isActive = true }
        else { scrollLeadingToSidebar.isActive = false; scrollLeadingToRoot.isActive = true }
        Self.setChip(backgroundChip, on: visible)
        if remember && Defaults[.annotateRememberBackgroundTool] { Defaults[.annotateBackgroundToolOpen] = visible }
        window?.layoutIfNeeded()
        if didInitialZoom && visible { zoomToFit() }
    }

    // MARK: - Keyboard

    private func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.control), let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift), option = flags.contains(.option)

        // Text editing (inline text, crop fields) gets the standard editing shortcuts.
        if let tv = window?.firstResponder as? NSTextView {
            switch ch {
            case "c": tv.copy(nil); return true
            case "x": tv.cut(nil); return true
            case "v": tv.pasteAsPlainText(nil); return true
            case "a": tv.selectAll(nil); return true
            case "z":
                if shift { tv.undoManager?.redo() } else { tv.undoManager?.undo() }
                return true
            case "\r" where canvas.editingID != nil:
                canvas.endTextEditing(); return true
            default: break
            }
            // Window-level commands still work while typing; everything else belongs to the text view.
            guard ch == "s" || ch == "w" || ch == "p" else { return false }
        }

        switch ch {
        case "z": endEditing(); if shift { session.redo() } else { session.undo() }
        case "c":
            if session.selection.isEmpty || canvas.isCropping { copyImage() } else { copyObjects() }
        case "x": copyObjects(); session.deleteSelection()
        case "v": paste()
        case "d": session.duplicateSelection()
        case "a": session.selectAll()
        case "s":
            if shift { saveAs() } else if option { saveProjectAs() } else { done() }
        case "\r": done()
        case "p": printImage()
        case "w": window?.performClose(nil)
        case "o": Services.annotate?.openWithPanel()
        case "i": if shift { addNewScreenshot() } else { addImageFromFile() }
        case "+", "=": zoom(by: 1.25)
        case "-": zoom(by: 0.8)
        case "0": zoomToFit()
        case "1": setZoom(1)
        case "]": session.arrangeSelection(option ? .front : .forward)
        case "[": session.arrangeSelection(option ? .back : .backward)
        default: return false
        }
        return true
    }

    private func endEditing() {
        if canvas.editingID != nil { canvas.endTextEditing() }
    }

    // MARK: - Object clipboard

    private func copyObjects() {
        let objs = session.selectedObjects
        guard !objs.isEmpty, let data = try? JSONEncoder().encode(objs) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.objectsPasteboardType)
        // Also offer a picture of the selection for other apps.
        var s = session.state
        s.objects = objs
        s.background = BackgroundSettings()
        s.cropRect = objs.reduce(CGRect.null) { $0.union($1.visualBounds) }
        let l = CompositionLayout.make(contentBounds: s.contentBounds(expand: false), background: s.background, scale: s.scale)
        if let img = objectsOnlyImage(s, layout: l), let png = ImageTools.pngData(img) { pb.setData(png, forType: .png) }
    }

    /// Renders only the objects (transparent background), used for "Copy Object to Clipboard".
    private func objectsOnlyImage(_ s: CanvasState, layout: CompositionLayout) -> CGImage? {
        guard let blank = ImageTools.context(width: 1, height: 1)?.makeImage() else { return nil }
        var copy = s
        copy.image = blank
        copy.scale = s.scale
        return session.renderer.export(copy, layout: layout)
    }

    private func paste() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.objectsPasteboardType), let objs = try? JSONDecoder().decode([Annotation].self, from: data) {
            session.insert(objs, offset: CGVector(dx: 12, dy: 12))
            session.tool = .select
            return
        }
        addImageFromClipboard()
    }

    // MARK: - Context menu

    private func contextMenu() -> NSMenu? {
        let m = NSMenu()
        if session.selection.isEmpty {
            let undo = NSMenuItem(title: "Undo", key: "z") { [weak self] in self?.session.undo() }
            undo.isEnabled = session.history.canUndo
            let redo = NSMenuItem(title: "Redo", key: "Z", modifiers: [.command, .shift]) { [weak self] in self?.session.redo() }
            redo.isEnabled = session.history.canRedo
            m.autoenablesItems = false
            m.addItem(undo)
            m.addItem(redo)
            m.addItem(.separator())
            m.addItem(NSMenuItem(title: "Paste", key: "v") { [weak self] in self?.paste() })
            m.addItem(NSMenuItem(title: "Select All", key: "a") { [weak self] in self?.session.selectAll() })
            m.addItem(NSMenuItem(title: "Copy Image", key: "c") { [weak self] in self?.copyImage() })
            m.addItem(.separator())
            m.addItem(NSMenuItem(title: "Save As…", key: "S", modifiers: [.command, .shift]) { [weak self] in self?.saveAs() })
            m.addItem(NSMenuItem(title: "Save Project…", key: "s", modifiers: [.command, .option]) { [weak self] in self?.saveProjectAs() })
            m.addItem(NSMenuItem(title: "Open Project…", key: "o") { Services.annotate?.openWithPanel() })
            let recent = NSMenuItem(title: "Open Recent Project", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.delegate = RecentProjectsMenuDelegate.shared
            recent.submenu = sub
            m.addItem(recent)
            m.addItem(.separator())
            m.addItem(NSMenuItem(title: "Print…", key: "p") { [weak self] in self?.printImage() })
            return m
        }
        m.addItem(NSMenuItem(title: "Copy Object to Clipboard", key: "c") { [weak self] in self?.copyObjects() })
        m.addItem(NSMenuItem(title: "Duplicate Object", key: "d") { [weak self] in self?.session.duplicateSelection() })
        m.addItem(NSMenuItem(title: "Delete", key: "\u{8}", modifiers: []) { [weak self] in self?.session.deleteSelection() })
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Bring to Front", key: "]", modifiers: [.command, .option]) { [weak self] in self?.session.arrangeSelection(.front) })
        m.addItem(NSMenuItem(title: "Bring Forward", key: "]") { [weak self] in self?.session.arrangeSelection(.forward) })
        m.addItem(NSMenuItem(title: "Send Backward", key: "[") { [weak self] in self?.session.arrangeSelection(.backward) })
        m.addItem(NSMenuItem(title: "Send to Back", key: "[", modifiers: [.command, .option]) { [weak self] in self?.session.arrangeSelection(.back) })
        if session.selection.count == 1, let id = session.selection.first, session.object(id)?.kind == .text {
            m.addItem(.separator())
            m.addItem(NSMenuItem(title: "Edit Text", key: "", modifiers: []) { [weak self] in self?.canvas.beginTextEditing(id, startState: nil) })
        }
        return m
    }

    // MARK: - Adding images

    private func addImageFromFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to add to the canvas"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let self else { return }
            self.handleDrop(panel.urls, at: nil)
        }
    }

    private func addImageFromClipboard() {
        guard let img = Clipboard.image(), let best = img.bestCGImage else {
            NSSound.beep()
            HUD.show("No image on the clipboard", symbol: "exclamationmark.circle.fill")
            return
        }
        session.addImageObject(best.image, scale: best.scale, center: visibleCenter)
    }

    private var visibleCenter: CGPoint {
        let v = canvas.visibleDocRect
        return CGPoint(x: v.midX, y: v.midY)
    }

    private func addNewScreenshot() {
        guard let capture = Services.capture, let window else { NSSound.beep(); return }
        guard Permissions.ensureScreenRecording() else { return }
        window.orderOut(nil)
        capture.selectArea(AreaSelectionOptions(purpose: .screenshot)) { [weak self] selection in
            guard let self else { return }
            guard let selection else { self.window?.makeKeyAndOrderFront(nil); return }
            Task { @MainActor in
                do {
                    let image: CGImage, scale: CGFloat
                    if let wid = selection.windowID {
                        (image, scale) = try await ScreenCapturer.capture(windowID: wid)
                    } else {
                        image = try await ScreenCapturer.capture(rect: selection.rect, on: selection.screen)
                        scale = selection.screen.backingScaleFactor
                    }
                    Sound.play(.capture)
                    self.window?.makeKeyAndOrderFront(nil)
                    self.session.addImageObject(image, scale: scale, center: self.visibleCenter)
                } catch {
                    self.window?.makeKeyAndOrderFront(nil)
                    Alerts.error("Couldn't take the screenshot.", error)
                }
            }
        }
    }

    private func handleDrop(_ urls: [URL], at p: CGPoint?) {
        var offset: CGFloat = 0
        for u in urls {
            if u.pathExtension.lowercased() == ShotcraftDocument.fileExtension {
                Services.annotate?.openDocument(u)
                continue
            }
            guard let img = NSImage(contentsOf: u), let best = img.bestCGImage else { continue }
            let c = p ?? visibleCenter
            session.addImageObject(best.image, scale: best.scale, center: CGPoint(x: c.x + offset, y: c.y + offset))
            offset += 16
        }
    }

    // MARK: - Committing

    private func prepareForExport() {
        endEditing()
        if canvas.isCropping { canvas.applyCrop() }
    }

    private func flattened() -> CGImage? {
        guard let img = session.flattenedImage() else {
            Alerts.error("Something went wrong saving your file.")
            return nil
        }
        return img
    }

    /// Writes the project next to the media in Application Support so the edit can be resumed later.
    @discardableResult
    private func saveSidecarProject(for m: CapturedMedia) -> Bool {
        let url = AppPaths.projects.appendingPathComponent(m.id.uuidString).appendingPathExtension(ShotcraftDocument.fileExtension)
        do {
            let data = try ShotcraftDocument.encode(session.state, sourceURL: m.url, createdAt: createdAt)
            try data.write(to: url, options: .atomic)
            m.projectURL = url
            return true
        } catch {
            Log.annotate.error("Project save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Applies the edit to a media file: the existing one (captures, opened files) or a new one in the
    /// media folder (clipboard / project sessions). Returns the media.
    @discardableResult
    private func commitToMedia(ingestNew: Set<AfterCaptureAction>) -> CapturedMedia? {
        prepareForExport()
        guard let image = flattened() else { return nil }
        let scale = session.state.scale
        if let m = media {
            var url = m.url
            let format: ImageFormat
            if let f = ImageFormat(fileExtension: url.pathExtension) {
                format = f
            } else {
                // A format we can't write (GIF, WebP, BMP…): never put PNG bytes behind that extension —
                // save next to it in the default format instead.
                format = Defaults[.screenshotFormat]
                url = AppPaths.uniqueURL(url.deletingPathExtension().appendingPathExtension(format.fileExtension))
            }
            do { try ImageTools.write(image, to: url, format: format, scale: scale) } catch {
                Alerts.error("Something went wrong saving your file.", error); return nil
            }
            m.url = url
            m.pixelSize = CGSize(width: image.width, height: image.height)
            m.scale = scale
            saveSidecarProject(for: m)
            m.notifyChanged()
            session.markClean()
            updateTitle()
            return m
        }
        let format = Defaults[.screenshotFormat]
        let url = AppPaths.uniqueURL(AppPaths.media.appendingPathComponent(baseName).appendingPathExtension(format.fileExtension))
        do { try ImageTools.write(image, to: url, format: format, scale: scale) } catch {
            Alerts.error("Something went wrong saving your file.", error); return nil
        }
        let m = CapturedMedia(url: url, kind: .image, mode: .imported,
                              pixelSize: CGSize(width: image.width, height: image.height), scale: scale)
        media = m
        saveSidecarProject(for: m)
        MediaPipeline.ingest(m, actions: ingestNew)
        if origin != .project { session.markClean() }
        updateTitle()
        return m
    }

    private func finishAndClose() {
        closeConfirmed = true
        close()
    }

    /// Done (⌘S / ⌘↩): apply changes and close.
    func done() {
        prepareForExport()
        switch origin {
        case .project:
            guard let url = projectURL, writeProject(to: url) else { saveProjectAs(closeAfter: true); return }
        case .clipboard where media == nil:
            guard commitToMedia(ingestNew: [.showQuickAccess]) != nil else { return }
        default:
            guard commitToMedia(ingestNew: []) != nil else { return }
        }
        finishAndClose()
    }

    /// Save button, per Settings → Annotate → "Save button behavior".
    func save() {
        prepareForExport()
        let ask = Defaults[.annotateSaveBehavior] == .askForDestination
        if media == nil || media.map({ $0.url.path.hasPrefix(AppPaths.media.path) && !$0.isSaved }) == true {
            guard let m = commitToMedia(ingestNew: []) else { return }
            guard let dest = MediaPipeline.save(m, askForDestination: ask) else { return }
            if origin == .project, let p = projectURL { writeProject(to: p) }
            HUD.show("Saved to \(dest.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle.fill")
            finishAndClose()
            return
        }
        if ask { saveAs(closeAfter: true); return }
        guard commitToMedia(ingestNew: []) != nil else { return }
        HUD.show("Saved", symbol: "checkmark.circle.fill")
        finishAndClose()
    }

    /// Save As… with a format popup (PNG / JPEG / HEIC / TIFF / Shotcraft Project).
    func saveAs(closeAfter: Bool = false) {
        prepareForExport()
        guard let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = AppPaths.exportLocation
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        var format = ExportFormat.from(Defaults[.annotateLastSaveFormat])
        if format == .project { format = .png }
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        let popup = UI.popup(ExportFormat.allCases.map(\.title), selected: ExportFormat.allCases.firstIndex(of: format) ?? 0, tooltip: "Format") { [weak panel] i in
            guard let panel else { return }
            let f = ExportFormat.allCases[i]
            panel.allowedContentTypes = [f.contentType]
            let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(stem).\(f.fileExtension)"
        }
        popup.controlSize = .regular
        let accessory = NSStackView(views: [UI.label("Format:", size: 13, color: .labelColor), popup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let self, let url = panel.url else { return }
            let f = ExportFormat.allCases[popup.indexOfSelectedItem]
            Defaults[.annotateLastSaveFormat] = f.fileExtension
            if f == .project {
                guard self.writeProject(to: url) else { return }
                self.projectURL = url
            } else {
                guard let img = self.flattened(), let imgFormat = f.imageFormat else { return }
                do { try ImageTools.write(img, to: url, format: imgFormat, scale: self.session.state.scale) } catch {
                    Alerts.error("Something went wrong saving your file.", error); return
                }
            }
            HUD.show("Saved", symbol: "checkmark.circle.fill")
            if closeAfter { self.finishAndClose() }
        }
    }

    /// Save Project… (.shotcraft).
    func saveProjectAs(closeAfter: Bool = false) {
        prepareForExport()
        guard let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = projectURL?.deletingLastPathComponent() ?? AppPaths.exportLocation
        panel.allowedContentTypes = [ExportFormat.project.contentType]
        panel.nameFieldStringValue = "\(baseName).\(ShotcraftDocument.fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let self, let url = panel.url else { return }
            guard self.writeProject(to: url) else { return }
            self.projectURL = url
            self.updateTitle()
            if closeAfter { self.finishAndClose() }
        }
    }

    @discardableResult
    private func writeProject(to url: URL) -> Bool {
        do {
            let data = try ShotcraftDocument.encode(session.state, sourceURL: media?.url, createdAt: createdAt)
            try data.write(to: url, options: .atomic)
            RecentProjects.add(url)
            if origin == .project { session.markClean() }
            updateTitle()
            return true
        } catch {
            Alerts.error("An error occurred while saving the project", error)
            return false
        }
    }

    // MARK: - Copy / upload / pin / share / print / drag

    /// ⌘C without a selection: copy the flattened image, keep editing.
    private func copyImage() {
        prepareForExport()
        guard let img = flattened() else { return }
        Clipboard.copy(image: img)
        Sound.play(.textCopied)
        HUD.show("Copied to clipboard")
    }

    private func copyAndClose() {
        guard let m = commitToMedia(ingestNew: []) else { return }
        Clipboard.copy(m)
        Sound.play(.textCopied)
        HUD.show("Copied to clipboard")
        finishAndClose()
    }

    private func uploadAndClose() {
        guard let m = commitToMedia(ingestNew: []) else { return }
        Services.upload?.upload(m, progress: nil, completion: nil)
        finishAndClose()
    }

    private func pinAndClose() {
        guard let m = commitToMedia(ingestNew: []) else { return }
        Services.pin?.pin(m)
        finishAndClose()
    }

    /// Flattened image in a temporary file (drag-me / share).
    private func writeTemporaryFile() -> URL? {
        prepareForExport()
        guard let img = flattened() else { return nil }
        let format = media.flatMap { ImageFormat(fileExtension: $0.url.pathExtension) } ?? Defaults[.screenshotFormat]
        let dir = AppPaths.ensure(AppPaths.temporary.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let url = dir.appendingPathComponent(baseName).appendingPathExtension(format.fileExtension)
        do { try ImageTools.write(img, to: url, format: format, scale: session.state.scale) } catch { return nil }
        return url
    }

    private func share(from view: NSView) {
        guard let url = writeTemporaryFile() else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func printImage() {
        prepareForExport()
        guard let img = flattened() else { return }
        ImagePrinter.print(img, scale: session.state.scale, title: baseName, window: window)
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        endEditing()
        guard !closeConfirmed, session.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = origin == .project ? "Do you want to save the changes made to this project?"
                                               : "Do you want to save the changes you made to the screenshot?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        let dont = alert.addButton(withTitle: "Don't Save")
        dont.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.done()
            case .alertSecondButtonReturn: self.finishAndClose()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        popover?.close()
        NotificationCenter.default.removeObserver(self)
        bridge.detach()
        onClose?(self)
    }
}

/// Fills "Open Recent Project" lazily.
@MainActor
final class RecentProjectsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentProjectsMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = RecentProjects.urls
        if urls.isEmpty {
            let none = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for u in urls {
            let item = NSMenuItem(title: u.deletingPathExtension().lastPathComponent, key: "", modifiers: []) {
                Services.annotate?.openDocument(u)
            }
            item.toolTip = u.path
            item.image = NSWorkspace.shared.icon(forFile: u.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear Menu", key: "", modifiers: []) { RecentProjects.clear() })
    }
}
