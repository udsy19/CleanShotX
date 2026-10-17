import AppKit
import SwiftUI
import Combine
import AVFoundation
import Carbon.HIToolbox
import SuperScreenshotCore

/// Window that routes unhandled keys to the editor's command handler.
final class EditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Text editing (title field) keeps its own ⌘Z etc.
        if firstResponder is NSTextView { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command), keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// A 1 pt divider drawn with a layer colour (no intrinsic size, so it can never resize the window).
final class HairlineView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = StudioTheme.hairline.cgColor }
}

/// The Studio editor window (Flow): top bar, icon rail + properties panel, live preview + transport, timeline.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSToolbarDelegate {
    let model: EditorModel
    private let player: PlayerController
    private let sidebarState = SidebarState()
    private var cancellables: Set<AnyCancellable> = []
    var onClose: (() -> Void)?

    private let preview = PreviewView()
    private var timeline: TimelineView!
    private let scrollView = TimelineScrollView()
    private let titleField = NSTextField()
    private let editedLabel = NSTextField(labelWithString: "Edited")
    private let timeLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private let expandButton = NSButton()
    private let scaleSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let loadingIndicator = NSProgressIndicator()

    // Export state.
    private var exporter: StudioExporter?
    private var progressWindow: NSWindow?
    private var dockSession: UUID?
    private var lastRate: Float = 1

    private enum ToolbarID {
        static let title = NSToolbarItem.Identifier("studio.title")
        static let more = NSToolbarItem.Identifier("studio.more")
        static let upload = NSToolbarItem.Identifier("studio.upload")
        static let export = NSToolbarItem.Identifier("studio.export")
    }

    init(model: EditorModel) {
        self.model = model
        player = PlayerController(model: model)
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1470, height: 850),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = StudioTheme.window
        window.minSize = NSSize(width: 1000, height: 640)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = model.project.title
        window.representedURL = model.package.url
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        let toolbar = NSToolbar(identifier: "SuperScreenshotStudioEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [ToolbarID.title]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        Artwork.shared.prepare()
        buildUI()
        bind()
        if !window.setFrameUsingName("SuperScreenshotStudioEditor"), let screen = NSScreen.main {
            let vis = screen.visibleFrame
            window.setContentSize(NSSize(width: min(1470, vis.width * 0.92), height: min(850, vis.height * 0.9)))
            window.center()
        }
        window.setFrameAutosaveName("SuperScreenshotStudioEditor")
        load(initial: true)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Top bar (toolbar)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.title, .flexibleSpace, ToolbarID.more, ToolbarID.upload, ToolbarID.export]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolbarID.title:
            titleField.stringValue = model.project.title
            titleField.isBordered = false
            titleField.drawsBackground = false
            titleField.isEditable = true
            titleField.alignment = .center
            titleField.font = .systemFont(ofSize: 13, weight: .medium)
            titleField.textColor = .labelColor
            titleField.focusRingType = .none
            titleField.lineBreakMode = .byTruncatingMiddle
            titleField.cell?.usesSingleLineMode = true
            titleField.delegate = self
            titleField.toolTip = "Click to rename the project"
            titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
            editedLabel.font = .systemFont(ofSize: 13)
            editedLabel.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [titleField, editedLabel])
            stack.spacing = 6
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = stack
            item.label = "Title"
            return item
        case ToolbarID.more:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
            item.showsIndicator = false
            item.label = "More"
            item.toolTip = "More"
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "Save Project") { [weak self] in self?.saveProject() })
            menu.addItem(ClosureMenuItem(title: "Export Current Frame as Image") { [weak self] in self?.exportCurrentFrame() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Reveal in Finder") { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([self.model.package.url])
            })
            item.menu = menu
            return item
        case ToolbarID.upload:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "Export & Upload")
            item.isBordered = true
            item.label = "Upload"
            item.toolTip = "Export & Upload to Cloud (⌘U)"
            item.target = self
            item.action = #selector(exportAndUploadClicked)
            return item
        case ToolbarID.export:
            let button = NSButton(title: "Export", target: self, action: #selector(exportClicked))
            button.bezelStyle = .push
            button.bezelColor = .controlAccentColor
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.toolTip = "Export Video (⌘E)"
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = button
            item.label = "Export"
            return item
        default:
            return nil
        }
    }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        // Left: icon rail + properties panel.
        sidebarState.thumbnail = { [weak self] t in await self?.player.sourceThumbnail(at: t, maxSize: CGSize(width: 480, height: 300)) }
        sidebarState.toggleCameraFullscreen = { [weak self] in self?.model.toggleCameraFullscreen() }
        let sidebar = NSHostingView(rootView: SidebarView(model: model, state: sidebarState))
        // The panel must never push its SwiftUI ideal size onto the window.
        sidebar.sizingOptions = []
        let sideLine = HairlineView()

        // Preview + transport.
        let previewArea = NSView()
        preview.onClick = { [weak self] p in self?.previewClicked(p) }
        expandButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full Screen")
        expandButton.isBordered = false
        expandButton.bezelStyle = .regularSquare
        expandButton.contentTintColor = .secondaryLabelColor
        expandButton.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        expandButton.target = self
        expandButton.action = #selector(toggleFullScreen)
        expandButton.toolTip = "Toggle Full Screen (⌘F)"
        let transport = makeTransport()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        [preview, expandButton, transport, loadingIndicator].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; previewArea.addSubview($0) }

        // Timeline.
        timeline = TimelineView(model: model, player: player)
        timeline.onScaleChange = { [weak self] pps in self?.syncScaleSlider(pps) }
        scrollView.documentView = timeline
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = StudioTheme.window
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.onZoom = { [weak self] f, x in self?.timeline.zoom(by: f, anchorX: x) }
        let timelineLine = HairlineView()

        for v in [sidebar, sideLine, previewArea, timelineLine, scrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let previewHeight = previewArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: timelineLine.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SidebarView.railWidth + 1 + SidebarView.panelWidth),
            sideLine.topAnchor.constraint(equalTo: content.topAnchor),
            sideLine.bottomAnchor.constraint(equalTo: timelineLine.topAnchor),
            sideLine.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sideLine.widthAnchor.constraint(equalToConstant: 1),

            previewArea.topAnchor.constraint(equalTo: content.topAnchor),
            previewArea.leadingAnchor.constraint(equalTo: sideLine.trailingAnchor),
            previewArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewArea.bottomAnchor.constraint(equalTo: timelineLine.topAnchor),
            previewHeight,
            preview.topAnchor.constraint(equalTo: previewArea.topAnchor),
            preview.leadingAnchor.constraint(equalTo: previewArea.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: transport.topAnchor),
            expandButton.topAnchor.constraint(equalTo: previewArea.topAnchor, constant: 12),
            expandButton.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor, constant: -14),
            transport.leadingAnchor.constraint(equalTo: previewArea.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: previewArea.bottomAnchor),
            transport.heightAnchor.constraint(equalToConstant: SidebarView.transportHeight),
            loadingIndicator.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: preview.centerYAnchor),

            timelineLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            timelineLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            timelineLine.heightAnchor.constraint(equalToConstant: 1),
            timelineLine.bottomAnchor.constraint(equalTo: scrollView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: timeline.contentHeight + 14),
        ])
        preview.playerLayer.player = player.player
        preview.canvasSize = player.previewCanvas
        NotificationCenter.default.addObserver(self, selector: #selector(timelineResized), name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
    }

    /// "00:08 / 00:22" · ⏮ ▶ ⏭ · "– ●──── +" timeline zoom.
    private func makeTransport() -> NSView {
        let bar = NSView()
        func button(_ symbol: String, _ tip: String, _ sel: Selector, size: CGFloat = 15) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: sel)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.toolTip = tip
            b.symbolConfiguration = .init(pointSize: size, weight: .medium)
            b.contentTintColor = .labelColor
            return b
        }
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.target = self; playButton.action = #selector(playClicked)
        playButton.isBordered = false; playButton.bezelStyle = .regularSquare
        playButton.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        playButton.contentTintColor = .labelColor
        playButton.toolTip = "Play / Pause (Space)"
        let center = NSStackView(views: [button("backward.end.fill", "Previous Cut / Start", #selector(jumpBack)), playButton,
                                         button("forward.end.fill", "Next Cut / End", #selector(jumpForward))])
        center.spacing = 18
        let minus = button("minus", "Zoom Timeline Out (⌘-)", #selector(zoomTimelineOut), size: 11)
        let plus = button("plus", "Zoom Timeline In (⌘=)", #selector(zoomTimelineIn), size: 11)
        minus.contentTintColor = .secondaryLabelColor; plus.contentTintColor = .secondaryLabelColor
        scaleSlider.controlSize = .small
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleSliderChanged)
        scaleSlider.toolTip = "Timeline zoom (⇧Z to fit)"
        let zoomStack = NSStackView(views: [minus, scaleSlider, plus])
        zoomStack.spacing = 6
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        [timeLabel, center, zoomStack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview($0) }
        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            timeLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            center.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            zoomStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            zoomStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scaleSlider.widthAnchor.constraint(equalToConstant: 110),
        ])
        return bar
    }

    @objc private func timelineResized() { timeline.updateWidth() }

    private func bind() {
        model.$playhead.combineLatest(model.$project).receive(on: DispatchQueue.main).sink { [weak self] t, _ in
            MainActor.assumeIsolated { self?.updateTimeLabel(t) }
        }.store(in: &cancellables)
        model.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] playing in
            MainActor.assumeIsolated {
                self?.playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playing ? "Pause" : "Play")
            }
        }.store(in: &cancellables)
        model.$isEdited.receive(on: DispatchQueue.main).sink { [weak self] edited in
            MainActor.assumeIsolated {
                self?.editedLabel.isHidden = !edited
                self?.window?.isDocumentEdited = edited
            }
        }.store(in: &cancellables)
        player.onCanvasChange = { [weak self] size in self?.preview.canvasSize = size }
        // Selecting a zoom opens the contextual Zoom panel; selecting a camera segment opens Camera.
        model.$selection.receive(on: DispatchQueue.main).sink { [weak self] sel in
            MainActor.assumeIsolated {
                guard let state = self?.sidebarState else { return }
                switch sel {
                case .zoom: state.tab = .zoom
                case .camera: state.showRail(.camera)
                default: if state.tab == .zoom { state.tab = state.railTab }
                }
            }
        }.store(in: &cancellables)
    }

    private func updateTimeLabel(_ t: Double) {
        let s = NSMutableAttributedString(string: TimeFormat.clock(t), attributes: [.foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: " / " + TimeFormat.clock(model.duration), attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        timeLabel.attributedStringValue = s
    }

    /// Loads the media (again after a rename moved the package) and the clip thumbnails.
    private func load(initial: Bool) {
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimation(nil)
        Task { @MainActor in
            do {
                try await player.load()
                loadingIndicator.stopAnimation(nil)
                loadingIndicator.isHidden = true
                timeline.thumbnails?.cancel()
                timeline.thumbnails = player.media.map { media in
                    let thumbs = ThumbnailProvider(asset: media.screenAsset)
                    thumbs.onUpdate = { [weak self] in self?.timeline.needsDisplay = true }
                    return thumbs
                }
                timeline.needsDisplay = true
                if initial {
                    timeline.zoomToFit()
                    player.seek(toOutput: 0)
                    if model.recovered { HUD.show("Recovered unsaved changes", symbol: "clock.arrow.circlepath") }
                } else {
                    player.seek(toOutput: model.playhead)
                }
            } catch {
                loadingIndicator.stopAnimation(nil)
                Alerts.error("An error occurred while opening the project", error)
                if initial { close() }
            }
        }
    }

    // MARK: Actions

    @objc private func playClicked() { player.togglePlay() }
    @objc private func jumpBack() { player.pause(); player.seek(toOutput: model.timeline.previousEdge(before: model.playhead)) }
    @objc private func jumpForward() { player.pause(); player.seek(toOutput: model.timeline.nextEdge(after: model.playhead)) }
    @objc private func zoomTimelineIn() { timeline.zoom(by: 1.5) }
    @objc private func zoomTimelineOut() { timeline.zoom(by: 1 / 1.5) }
    @objc private func toggleFullScreen() { window?.toggleFullScreen(nil) }

    /// The slider is logarithmic over the allowed scale range.
    @objc private func scaleSliderChanged() {
        let lo = log(TimelineGeometry.minScale), hi = log(TimelineGeometry.maxScale)
        timeline.setScale(exp(lo + scaleSlider.doubleValue * (hi - lo)))
    }

    private func syncScaleSlider(_ pps: Double) {
        let lo = log(TimelineGeometry.minScale), hi = log(TimelineGeometry.maxScale)
        scaleSlider.doubleValue = (log(pps) - lo) / (hi - lo)
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func saveDocument(_ sender: Any?) { saveProject() }

    private func previewClicked(_ canvasPoint: CGPoint) {
        guard model.hasCamera else { return }
        let scene = player.currentScene
        let layout = scene.layout(for: preview.canvasSize)
        let t = model.playheadSource
        let vp = scene.viewport(at: t, layout: layout)
        if let (rect, _) = scene.cameraRect(at: t, layout: layout, zoomScale: vp.scale), rect.contains(canvasPoint) {
            model.toggleCameraFullscreen()
        }
    }

    private func saveProject() {
        do { try model.save() } catch { Alerts.error("An error occurred while saving the project", error) }
    }

    // MARK: Keyboard

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = mods.contains(.shift)
        if mods.contains(.command) {
            switch chars {
            case "z": if shift { model.redo() } else { model.undo() }
            case "s": saveProject()
            case "e": if shift { exportCurrentFrame() } else { exportClicked() }
            case "u": exportAndUploadClicked()
            case "b": if shift { model.splitZoomAtPlayhead() } else { model.splitClipAtPlayhead() }
            case "f": toggleFullScreen()
            case "w": window?.performClose(nil)
            case "=", "+": timeline.zoom(by: 1.5)
            case "-": timeline.zoom(by: 1 / 1.5)
            default: return false
            }
            return true
        }
        switch Int(e.keyCode) {
        case kVK_Space: player.togglePlay(); return true
        case kVK_LeftArrow: player.step(frames: shift ? -10 : -1); return true
        case kVK_RightArrow: player.step(frames: shift ? 10 : 1); return true
        case kVK_UpArrow: jumpBack(); return true
        case kVK_DownArrow: jumpForward(); return true
        case kVK_Home: player.pause(); player.seek(toOutput: 0); return true
        case kVK_End: player.pause(); player.seek(toOutput: model.duration); return true
        case kVK_Delete, kVK_ForwardDelete: model.deleteSelection(); return true
        case kVK_Escape: model.selection = .none; model.tool = .selection; return true
        default: break
        }
        guard !mods.contains(.control), !mods.contains(.option) else { return false }
        switch chars {
        case "b" where !shift: model.tool = .cut; return true
        case "v" where !shift: model.tool = .selection; return true
        case "z" where shift: timeline.zoomToFit(); return true
        case "f" where !shift: model.toggleCameraFullscreen(); return true
        case "k": player.pause(); return true
        case "l":
            lastRate = player.player.rate > 0 ? min(player.player.rate * 2, 4) : 1
            player.play(rate: lastRate); return true
        case "j":
            lastRate = player.player.rate < 0 ? max(player.player.rate * 2, -4) : -1
            player.play(rate: lastRate); return true
        default: return false
        }
    }

    // MARK: Title

    func controlTextDidEndEditing(_ obj: Notification) {
        let new = titleField.stringValue
        defer { window?.makeFirstResponder(nil) }
        // Renaming moves the package; an export in progress still reads from it.
        guard exporter == nil, !new.trimmingCharacters(in: .whitespaces).isEmpty else {
            if exporter != nil { NSSound.beep() }
            titleField.stringValue = model.project.title
            return
        }
        let oldURL = model.package.url
        model.rename(to: new)
        titleField.stringValue = model.project.title
        window?.title = model.project.title
        window?.representedURL = model.package.url
        if model.package.url != oldURL { load(initial: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            titleField.stringValue = model.project.title
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    // MARK: Export

    @objc private func exportClicked() { showExportPanel(upload: false) }
    @objc private func exportAndUploadClicked() { showExportPanel(upload: true) }

    private func showExportPanel(upload: Bool) {
        guard exporter == nil, window?.attachedSheet == nil, let window, player.media != nil else { NSSound.beep(); return }
        player.pause()
        let p = model.project
        let hasAudio = (p.recording.hasMicrophone && p.style.audio.includeMicrophone) || (p.recording.hasSystemAudio && p.style.audio.includeSystemAudio)
        let panelModel = ExportPanelModel(base: CanvasLayout.baseCanvasSize(sourceSize: p.recording.pixelSize, style: p.style),
                                          duration: model.duration, hasAudio: hasAudio, upload: upload)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ExportPanelView(model: panelModel)))
        sheet.styleMask = [.titled]
        panelModel.onCancel = { [weak window, weak sheet] in if let sheet { window?.endSheet(sheet) } }
        panelModel.onExport = { [weak self, weak window, weak sheet] settings in
            if let sheet { window?.endSheet(sheet) }
            self?.startExport(settings, upload: upload)
        }
        window.beginSheet(sheet)
    }

    private func startExport(_ settings: ExportSettings, upload: Bool) {
        guard let media = player.media, let window else { return }
        let ext = settings.format.fileExtension
        let url = AppPaths.uniqueURL(AppPaths.recordings.appendingPathComponent(model.project.title).appendingPathExtension(ext))
        let exp: StudioExporter
        do {
            exp = try StudioExporter(project: model.project, events: model.events, package: model.package, media: media, settings: settings, outputURL: url)
        } catch {
            Alerts.error("Failed to prepare the video composition for export.", error); return
        }
        exporter = exp
        let progressModel = RenderProgressModel()
        progressModel.onCancel = { [weak self] in self?.confirmCancelExport() }
        let pw = NSWindow(contentViewController: NSHostingController(rootView: RenderProgressView(model: progressModel)))
        pw.styleMask = [.titled]
        window.beginSheet(pw)
        progressWindow = pw
        let session = UUID()
        dockSession = session
        let kind: MediaKind = settings.format == .gif ? .gif : .video
        let base = CanvasLayout.baseCanvasSize(sourceSize: model.project.recording.pixelSize, style: model.project.style)
        let scale = max(1, model.project.recording.scale * Double(exp.outputSize.width / max(base.width, 1)))
        exp.start(progress: { p in
            MainActor.assumeIsolated {
                progressModel.update(p)
                DockProgress.update(session, p)
            }
        }, completion: { [weak self] result in
            MainActor.assumeIsolated {
                DockProgress.end(session)
                guard let self else { return }
                self.dockSession = nil
                if let pw = self.progressWindow { self.window?.endSheet(pw) }
                self.progressWindow = nil
                self.exporter = nil
                switch result {
                case .success(let url):
                    Sound.play(.exportDone)
                    var actions = Defaults[.afterRecordingActions]
                    if upload { actions.insert(.upload) }
                    MediaPipeline.didFinishRecording(url: url, kind: kind, mode: .studio, pixelSize: exp.outputSize, scale: CGFloat(scale),
                                                     actions: actions)
                case .failure(let error):
                    if case StudioExporter.ExportError.cancelled = error { return }
                    Alerts.error("An error occurred while processing the video file.", error)
                }
            }
        })
    }

    private func confirmCancelExport() {
        guard exporter != nil else { return }
        if Alerts.confirm("Are you sure you want to stop the processing?",
                          info: "The export is still in progress. You'll need to start over if you stop now.",
                          confirmTitle: "Stop", destructive: true) {
            exporter?.cancel()
        }
    }

    private func exportCurrentFrame() {
        player.pause()
        let p = model.project
        let canvas = CanvasLayout.baseCanvasSize(sourceSize: p.recording.pixelSize, style: p.style)
        Task { @MainActor in
            guard let img = await player.currentFrameImage(canvas: canvas) else { NSSound.beep(); return }
            MediaPipeline.didCaptureImage(img, scale: CGFloat(p.recording.scale), mode: .studio)
        }
    }

    // MARK: Window

    func windowDidEnterFullScreen(_ notification: Notification) {
        expandButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Exit Full Screen")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        expandButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full Screen")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if exporter != nil {
            guard Alerts.confirm("The export is still in progress. Do you want to cancel it?", confirmTitle: "Cancel Export", cancelTitle: "Continue") else { return false }
            exporter?.cancel()
        }
        guard model.isEdited else { return true }
        let a = NSAlert()
        a.messageText = "Do you want to save your project before closing?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            do { try model.save(); return true } catch { Alerts.error("An error occurred while saving the project", error); return false }
        case .alertSecondButtonReturn:
            model.discardChanges()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        player.invalidate()
        timeline.thumbnails?.cancel()
        if let s = dockSession { DockProgress.end(s) }
        StudioStyleMemory.remember(model.project.style)
        NotificationCenter.default.removeObserver(self)
        cancellables.removeAll()
        onClose?()
    }
}
