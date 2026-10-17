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
    private var propertiesBar: PropertiesBar!
    private var sidebar: BackgroundSidebar!
    /// Scroll view leading edge: to the window edge, or to the background sidebar when it is shown.
    private var scrollLeadingToRoot: NSLayoutConstraint!
    private var scrollLeadingToSidebar: NSLayoutConstraint!
    private let toolControl = NSSegmentedControl()
    private let historyControl = NSSegmentedControl()
    private var backgroundButton: NSButton!
    private var zoomButton: NSPopUpButton!
    private var sizeLabel: NSTextField!
    private var dragHandle: DragHandleView!
    private var closeConfirmed = false
    private var didInitialZoom = false

    private static let objectsPasteboardType = NSPasteboard.PasteboardType("com.udsy.shotcraft.annotations")

    init(state: CanvasState, origin: Origin, media: CapturedMedia?, projectURL: URL?, createdAt: Date = Date()) {
        self.session = EditorSession(state: state)
        self.origin = origin
        self.media = media
        self.projectURL = projectURL
        self.createdAt = createdAt
        self.canvas = CanvasView(session: session)
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 480)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.keyHandler = { [weak self] e in self?.handleKeyEquivalent(e) ?? false }
        window.titleVisibility = .hidden
        buildToolbar(window)
        buildContent(window)
        session.observe { [weak self] change in self?.sessionChanged(change) }
        session.renderer.desktopWallpaperPath = { [weak window] in
            guard let s = window?.screen ?? NSScreen.main, let u = NSWorkspace.shared.desktopImageURL(for: s) else { return nil }
            return u.path
        }
        updateTitle()
        updateHistoryButtons()
        updateSizeLabel()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: - Building

    private enum ItemID {
        static let tools = NSToolbarItem.Identifier("annotate.tools")
        static let add = NSToolbarItem.Identifier("annotate.add")
        static let background = NSToolbarItem.Identifier("annotate.background")
        static let history = NSToolbarItem.Identifier("annotate.history")
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
        [ItemID.tools, ItemID.add, ItemID.background, .flexibleSpace, ItemID.history]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case ItemID.tools:
            let tools = AnnotateTool.allCases
            toolControl.segmentCount = tools.count
            toolControl.trackingMode = .selectOne
            toolControl.segmentStyle = .separated
            for (i, t) in tools.enumerated() {
                let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                    ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: t.title)!
                toolControl.setImage(img, forSegment: i)
                toolControl.setToolTip("\(t.title) (\(String(t.key).uppercased()))", forSegment: i)
                toolControl.setWidth(30, forSegment: i)
            }
            toolControl.selectedSegment = tools.firstIndex(of: session.tool) ?? 0
            toolControl.onAction { [weak self] _ in
                guard let self else { return }
                let t = AnnotateTool.allCases[self.toolControl.selectedSegment]
                if t == .crop { self.canvas.startCrop() } else { self.session.tool = t }
                self.window?.makeFirstResponder(self.canvas)
            }
            item.view = toolControl
            item.label = "Tools"
        case ItemID.add:
            let b = NSPopUpButton(frame: .zero, pullsDown: true)
            b.bezelStyle = .texturedRounded
            b.toolTip = "Add an image"
            let menu = NSMenu()
            let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            title.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "Add image")
            menu.addItem(title)
            menu.addItem(NSMenuItem(title: "Add Screenshot From File…", key: "", modifiers: []) { [weak self] in self?.addImageFromFile() })
            menu.addItem(NSMenuItem(title: "Paste From Clipboard", key: "", modifiers: []) { [weak self] in self?.addImageFromClipboard() })
            menu.addItem(NSMenuItem(title: "Add New Screenshot", key: "", modifiers: []) { [weak self] in self?.addNewScreenshot() })
            b.menu = menu
            item.view = b
            item.label = "Add Image"
        case ItemID.background:
            let b = NSButton(image: NSImage(systemSymbolName: "rectangle.inset.filled.and.person.filled", accessibilityDescription: "Background")
                             ?? NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Background")!,
                             target: nil, action: nil)
            b.bezelStyle = .texturedRounded
            b.setButtonType(.pushOnPushOff)
            b.toolTip = "Background Tool (G)"
            b.onAction { [weak self] _ in self?.toggleBackgroundTool() }
            backgroundButton = b
            item.view = b
            item.label = "Background"
        case ItemID.history:
            historyControl.segmentCount = 2
            historyControl.trackingMode = .momentary
            historyControl.setImage(NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo"), forSegment: 0)
            historyControl.setImage(NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo"), forSegment: 1)
            historyControl.setToolTip("Undo (⌘Z)", forSegment: 0)
            historyControl.setToolTip("Redo (⇧⌘Z)", forSegment: 1)
            historyControl.onAction { [weak self] _ in
                guard let self else { return }
                self.endEditing()
                if self.historyControl.selectedSegment == 0 { self.session.undo() } else { self.session.redo() }
            }
            item.view = historyControl
            item.label = "Undo"
        default:
            return nil
        }
        return item
    }

    private func buildContent(_ window: NSWindow) {
        let root = NSView()
        window.contentView = root

        propertiesBar = PropertiesBar(session: session, canvas: canvas, bridge: bridge)
        let props = NSVisualEffectView()
        props.material = .titlebar
        props.blendingMode = .withinWindow
        props.translatesAutoresizingMaskIntoConstraints = false
        propertiesBar.translatesAutoresizingMaskIntoConstraints = false
        props.addSubview(propertiesBar)

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
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        canvas.onDropFiles = { [weak self] urls, p in self?.handleDrop(urls, at: p) }
        canvas.contextMenuProvider = { [weak self] in self?.contextMenu() }
        canvas.extraKeyHandler = { [weak self] ch in
            if ch == "g" { self?.toggleBackgroundTool(); return true }
            return false
        }

        let bottom = buildBottomBar()
        let topLine = NSBox(); topLine.boxType = .separator; topLine.translatesAutoresizingMaskIntoConstraints = false
        let bottomLine = NSBox(); bottomLine.boxType = .separator; bottomLine.translatesAutoresizingMaskIntoConstraints = false

        [props, topLine, sidebar, scrollView, bottomLine, bottom].forEach { root.addSubview($0) }
        scrollLeadingToRoot = scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        scrollLeadingToSidebar = scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        NSLayoutConstraint.activate([
            props.topAnchor.constraint(equalTo: root.topAnchor),
            props.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            props.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            props.heightAnchor.constraint(equalToConstant: 38),
            propertiesBar.leadingAnchor.constraint(equalTo: props.leadingAnchor),
            propertiesBar.trailingAnchor.constraint(equalTo: props.trailingAnchor),
            propertiesBar.topAnchor.constraint(equalTo: props.topAnchor),
            propertiesBar.bottomAnchor.constraint(equalTo: props.bottomAnchor),
            topLine.topAnchor.constraint(equalTo: props.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            sidebar.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollLeadingToRoot,

            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func buildBottomBar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false

        zoomButton = NSPopUpButton(frame: .zero, pullsDown: true)
        zoomButton.bezelStyle = .texturedRounded
        zoomButton.controlSize = .small
        zoomButton.toolTip = "Zoom"
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
        zoomButton.widthAnchor.constraint(equalToConstant: 76).isActive = true

        sizeLabel = UI.label("", size: 11)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        dragHandle = DragHandleView()
        dragHandle.fileProvider = { [weak self] in self?.writeTemporaryFile() }

        let print = UI.symbolButton("printer", tooltip: "Print… (⌘P)") { [weak self] in self?.printImage() }
        let share = UI.symbolButton("square.and.arrow.up", tooltip: "Share") { }
        share.onAction { [weak self, weak share] _ in if let share { self?.share(from: share) } }
        let pin = UI.symbolButton("pin", tooltip: "Pin to the screen") { [weak self] in self?.pinAndClose() }
        let upload = UI.symbolButton("icloud.and.arrow.up", tooltip: "Upload") { [weak self] in self?.uploadAndClose() }
        let copy = UI.textButton("Copy", tooltip: "Copy to clipboard and close") { [weak self] in self?.copyAndClose() }

        let save = NSSegmentedControl()
        save.segmentCount = 2
        save.trackingMode = .momentary
        save.setLabel("Save", forSegment: 0)
        save.setToolTip(Defaults[.annotateSaveBehavior] == .askForDestination ? "Save… " : "Save to the export location", forSegment: 0)
        save.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More save options"), forSegment: 1)
        save.setWidth(18, forSegment: 1)
        let menu = saveMenu()
        save.onAction { [weak self, weak save] _ in
            guard let self, let save else { return }
            if save.selectedSegment == 0 { self.save() }
            else { menu.popUp(positioning: nil, at: NSPoint(x: save.bounds.maxX - 18, y: save.bounds.maxY + 4), in: save) }
        }

        let done = UI.textButton("Done") { [weak self] in self?.done() }
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        done.toolTip = "Apply changes and close (⌘S)"
        done.bezelColor = .controlAccentColor

        let left = NSStackView(views: [zoomButton, sizeLabel])
        left.spacing = 10
        let right = NSStackView(views: [dragHandle, UI.separator(), print, share, pin, upload, UI.separator(), copy, save, done])
        right.spacing = 8
        for s in [left, right] { s.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(s) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
        ])
        return bar
    }

    private func saveMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "Save As…", key: "S", modifiers: [.command, .shift]) { [weak self] in self?.saveAs() })
        m.addItem(NSMenuItem(title: "Save Project…", key: "s", modifiers: [.command, .option]) { [weak self] in self?.saveProjectAs() })
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Open Project…", key: "o") { Services.annotate?.openWithPanel() })
        let recent = NSMenuItem(title: "Open Recent Project", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.delegate = RecentProjectsMenuDelegate.shared
        recent.submenu = sub
        m.addItem(recent)
        return m
    }

    // MARK: - Showing

    /// Sizes the window around the image (≤ 90 % of the screen) and zooms to fit.
    func present() {
        guard let window else { return }
        let screen = NSScreen.active.visibleFrame
        let out = canvas.frame.size
        let chrome = CGSize(width: 0, height: 38 + 46 + 52)
        let w = min(max(out.width + 40, 860), screen.width * 0.9)
        let h = min(max(out.height + chrome.height + 30, 540), screen.height * 0.9)
        window.setFrame(NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h), display: false)
        window.level = Defaults[.annotateAlwaysOnTop] ? .floating : .normal
        if Defaults[.annotateRememberBackgroundTool] && Defaults[.annotateBackgroundToolOpen] { setBackgroundTool(visible: true, remember: false) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        zoomToFit()
        didInitialZoom = true
        window.makeFirstResponder(canvas)
    }

    // MARK: - Session changes

    private func sessionChanged(_ change: EditorSession.Change) {
        switch change {
        case .tool:
            toolControl.selectedSegment = AnnotateTool.allCases.firstIndex(of: session.tool) ?? 0
        case .content:
            updateHistoryButtons()
            updateTitle()
            updateSizeLabel()
        default:
            break
        }
    }

    private func updateHistoryButtons() {
        historyControl.setEnabled(session.history.canUndo, forSegment: 0)
        historyControl.setEnabled(session.history.canRedo, forSegment: 1)
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
        scrollLeadingToRoot.isActive = !visible
        scrollLeadingToSidebar.isActive = visible
        backgroundButton?.state = visible ? .on : .off
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
            m.addItem(NSMenuItem(title: "Paste", key: "v") { [weak self] in self?.paste() })
            m.addItem(NSMenuItem(title: "Select All", key: "a") { [weak self] in self?.session.selectAll() })
            m.addItem(.separator())
            m.addItem(NSMenuItem(title: "Copy Image", key: "c") { [weak self] in self?.copyImage() })
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
            let format = ImageFormat(fileExtension: m.url.pathExtension) ?? Defaults[.screenshotFormat]
            do { try ImageTools.write(image, to: m.url, format: format, scale: scale) } catch {
                Alerts.error("Something went wrong saving your file.", error); return nil
            }
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
