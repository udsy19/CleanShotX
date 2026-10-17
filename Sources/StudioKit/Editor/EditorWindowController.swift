import AppKit
import SwiftUI
import Combine
import AVFoundation
import Carbon.HIToolbox
import ShotcraftCore

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

/// The Studio editor window (Flow): top bar, live preview + transport, property sidebar, timeline.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
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
    private let timeLabel = NSTextField(labelWithString: "0:00.0 / 0:00.0")
    private let playButton = NSButton()
    private var sidebar: NSView!
    private var sidebarWidth: NSLayoutConstraint!
    private let loadingIndicator = NSProgressIndicator()

    // Export state.
    private var exporter: StudioExporter?
    private var progressWindow: NSWindow?
    private var dockSession: UUID?
    private var lastRate: Float = 1

    init(model: EditorModel) {
        self.model = model
        player = PlayerController(model: model)
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 960, height: 620)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = model.project.title
        window.representedURL = model.package.url
        window.setFrameAutosaveName("ShotcraftStudioEditor")
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        Artwork.shared.prepare()
        buildUI()
        bind()
        if window.frame.origin == .zero { window.center() }
        load()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        // Top bar
        let top = NSVisualEffectView()
        top.material = .titlebar
        top.blendingMode = .withinWindow
        titleField.stringValue = model.project.title
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = true
        titleField.alignment = .center
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.delegate = self
        titleField.toolTip = "Click to rename the project"
        editedLabel.font = .systemFont(ofSize: 11)
        editedLabel.textColor = .tertiaryLabelColor
        let titleStack = NSStackView(views: [titleField, editedLabel])
        titleStack.spacing = 6
        let exportButton = NSButton(title: "Export", target: self, action: #selector(exportClicked))
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .large
        exportButton.keyEquivalent = ""
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportButton.imagePosition = .imageLeading
        if #available(macOS 14.0, *) { exportButton.bezelColor = .controlAccentColor }
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.bezelStyle = .texturedRounded
        more.isBordered = false
        let moreMenu = NSMenu()
        let header = NSMenuItem(); header.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        moreMenu.addItem(header)
        moreMenu.addItem(ClosureMenuItem(title: "Save Project") { [weak self] in self?.saveProject() })
        moreMenu.addItem(ClosureMenuItem(title: "Export Current Frame as Image") { [weak self] in self?.exportCurrentFrame() })
        moreMenu.addItem(ClosureMenuItem(title: "Reveal in Finder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.model.package.url])
        })
        more.menu = moreMenu
        let sidebarToggle = NSButton(image: NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Toggle Sidebar")!,
                                     target: self, action: #selector(toggleSidebar))
        sidebarToggle.bezelStyle = .texturedRounded
        sidebarToggle.isBordered = false
        let rightStack = NSStackView(views: [more, sidebarToggle, exportButton])
        rightStack.spacing = 8
        let topSeparator = NSBox(); topSeparator.boxType = .separator
        [titleStack, rightStack, topSeparator].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; top.addSubview($0) }

        // Preview + transport
        let previewArea = NSView()
        previewArea.wantsLayer = true
        previewArea.layer?.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black)?.cgColor
        preview.onClick = { [weak self] p in self?.previewClicked(p) }
        let transport = NSStackView()
        transport.spacing = 10
        func tbutton(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: sel)
            b.bezelStyle = .texturedRounded; b.isBordered = false; b.toolTip = tip
            b.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            return b
        }
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.target = self; playButton.action = #selector(playClicked)
        playButton.bezelStyle = .texturedRounded; playButton.isBordered = false
        playButton.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        playButton.toolTip = "Play / Pause (Space)"
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        transport.addArrangedSubview(tbutton("backward.frame.fill", "Previous Frame (←)", #selector(prevFrame)))
        transport.addArrangedSubview(playButton)
        transport.addArrangedSubview(tbutton("forward.frame.fill", "Next Frame (→)", #selector(nextFrame)))
        transport.addArrangedSubview(timeLabel)
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        [preview, transport, loadingIndicator].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; previewArea.addSubview($0) }

        // Sidebar
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        sidebarState.thumbnail = { [weak self] t in await self?.player.sourceThumbnail(at: t, maxSize: CGSize(width: 560, height: 360)) }
        sidebarState.toggleCameraFullscreen = { [weak self] in self?.model.toggleCameraFullscreen() }
        let host = NSHostingView(rootView: SidebarView(model: model, state: sidebarState))
        host.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(host)
        sidebar = side
        let sideSeparator = NSBox(); sideSeparator.boxType = .separator
        // Vertical separator: a zero-frame NSBox defaults to horizontal (hugging height 1), which would collapse the window.
        sideSeparator.setContentHuggingPriority(.init(1), for: .vertical)
        sideSeparator.setContentCompressionResistancePriority(.init(1), for: .vertical)

        // Timeline + toolbar
        timeline = TimelineView(model: model, player: player)
        scrollView.documentView = timeline
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.onZoom = { [weak self] f, x in self?.timeline.zoom(by: f, anchorX: x) }
        scrollView.contentView.postsBoundsChangedNotifications = true
        let toolbar = NSStackView()
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        toolbar.addArrangedSubview(tbutton("scissors", "Split Clip at Playhead (S)", #selector(splitClip)))
        toolbar.addArrangedSubview(tbutton("plus.magnifyingglass", "Split Zoom at Playhead (⌥S)", #selector(splitZoom)))
        toolbar.addArrangedSubview(tbutton("trash", "Delete Selection (⌫)", #selector(deleteSelection)))
        if model.hasCamera { toolbar.addArrangedSubview(tbutton("web.camera", "Toggle Camera Fullscreen (F)", #selector(toggleCameraFullscreen))) }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(tbutton("minus.magnifyingglass", "Zoom Timeline Out (⌘-)", #selector(zoomTimelineOut)))
        toolbar.addArrangedSubview(tbutton("arrow.left.and.right.square", "Zoom Timeline to Fit (⇧Z)", #selector(zoomTimelineToFit)))
        toolbar.addArrangedSubview(tbutton("plus.magnifyingglass", "Zoom Timeline In (⌘+)", #selector(zoomTimelineIn)))
        let bottomSeparator = NSBox(); bottomSeparator.boxType = .separator

        for v in [top, previewArea, side, sideSeparator, toolbar, bottomSeparator, scrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        sidebarWidth = side.widthAnchor.constraint(equalToConstant: 300)
        let timelineHeight = scrollView.heightAnchor.constraint(equalToConstant: CGFloat(timeline.contentHeight) + 16)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: 52),
            titleStack.centerXAnchor.constraint(equalTo: top.centerXAnchor),
            titleStack.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            rightStack.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            topSeparator.bottomAnchor.constraint(equalTo: top.bottomAnchor),

            side.topAnchor.constraint(equalTo: top.bottomAnchor),
            side.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            side.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            sidebarWidth,
            sideSeparator.topAnchor.constraint(equalTo: side.topAnchor),
            sideSeparator.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            sideSeparator.trailingAnchor.constraint(equalTo: side.leadingAnchor),
            sideSeparator.widthAnchor.constraint(equalToConstant: 1),
            host.topAnchor.constraint(equalTo: side.topAnchor),
            host.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: side.trailingAnchor),

            previewArea.topAnchor.constraint(equalTo: top.bottomAnchor),
            previewArea.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            previewArea.trailingAnchor.constraint(equalTo: sideSeparator.leadingAnchor),
            previewArea.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            preview.topAnchor.constraint(equalTo: previewArea.topAnchor),
            preview.leadingAnchor.constraint(equalTo: previewArea.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: transport.topAnchor, constant: -4),
            transport.centerXAnchor.constraint(equalTo: previewArea.centerXAnchor),
            transport.bottomAnchor.constraint(equalTo: previewArea.bottomAnchor, constant: -8),
            transport.heightAnchor.constraint(equalToConstant: 30),
            loadingIndicator.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: preview.centerYAnchor),

            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),
            toolbar.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: scrollView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            timelineHeight,
        ])
        preview.playerLayer.player = player.player
        preview.canvasSize = player.previewCanvas
        NotificationCenter.default.addObserver(self, selector: #selector(timelineResized), name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
    }

    @objc private func timelineResized() { timeline.updateWidth() }

    private func bind() {
        model.$playhead.combineLatest(model.$project).receive(on: DispatchQueue.main).sink { [weak self] t, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timeLabel.stringValue = "\(TimeFormat.string(t)) / \(TimeFormat.string(self.model.duration))"
            }
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
        // Selecting a zoom opens the Zoom panel; selecting a camera segment opens Camera.
        model.$selection.receive(on: DispatchQueue.main).sink { [weak self] sel in
            MainActor.assumeIsolated {
                switch sel {
                case .zoom: self?.sidebarState.tab = .zoom
                case .camera: self?.sidebarState.tab = .camera
                default: break
                }
            }
        }.store(in: &cancellables)
    }

    private func load() {
        loadingIndicator.startAnimation(nil)
        Task { @MainActor in
            do {
                try await player.load()
                loadingIndicator.stopAnimation(nil)
                loadingIndicator.isHidden = true
                if let media = player.media {
                    let thumbs = ThumbnailProvider(asset: media.screenAsset)
                    thumbs.onUpdate = { [weak self] in self?.timeline.needsDisplay = true }
                    timeline.thumbnails = thumbs
                }
                timeline.zoomToFit()
                player.seek(toOutput: 0)
                if model.recovered { HUD.show("Recovered unsaved changes", symbol: "clock.arrow.circlepath") }
            } catch {
                loadingIndicator.stopAnimation(nil)
                Alerts.error("An error occurred while opening the project", error)
                close()
            }
        }
    }

    // MARK: Actions

    @objc private func playClicked() { player.togglePlay() }
    @objc private func prevFrame() { player.step(frames: -1) }
    @objc private func nextFrame() { player.step(frames: 1) }
    @objc private func splitClip() { model.splitClipAtPlayhead() }
    @objc private func splitZoom() { model.splitZoomAtPlayhead() }
    @objc private func deleteSelection() { model.deleteSelection() }
    @objc private func toggleCameraFullscreen() { model.toggleCameraFullscreen() }
    @objc private func zoomTimelineIn() { timeline.zoom(by: 1.5) }
    @objc private func zoomTimelineOut() { timeline.zoom(by: 1 / 1.5) }
    @objc private func zoomTimelineToFit() { timeline.zoomToFit() }

    @objc private func toggleSidebar() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            sidebarWidth.animator().constant = sidebarWidth.constant > 0 ? 0 : 300
            window?.contentView?.layoutSubtreeIfNeeded()
        }
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
        if mods.contains(.command) {
            switch (chars, mods.contains(.shift)) {
            case ("z", false): model.undo(); return true
            case ("z", true): model.redo(); return true
            case ("s", _): saveProject(); return true
            case ("e", false): exportClicked(); return true
            case ("e", true): exportCurrentFrame(); return true
            case ("=", _), ("+", _): timeline.zoom(by: 1.5); return true
            case ("-", _): timeline.zoom(by: 1 / 1.5); return true
            default: return false
            }
        }
        let shift = mods.contains(.shift)
        switch Int(e.keyCode) {
        case kVK_Space: player.togglePlay(); return true
        case kVK_LeftArrow: player.step(frames: shift ? -10 : -1); return true
        case kVK_RightArrow: player.step(frames: shift ? 10 : 1); return true
        case kVK_UpArrow: player.pause(); player.seek(toOutput: model.timeline.previousEdge(before: model.playhead)); return true
        case kVK_DownArrow: player.pause(); player.seek(toOutput: model.timeline.nextEdge(after: model.playhead)); return true
        case kVK_Home: player.pause(); player.seek(toOutput: 0); return true
        case kVK_End: player.pause(); player.seek(toOutput: model.duration); return true
        case kVK_Delete, kVK_ForwardDelete: model.deleteSelection(); return true
        case kVK_Escape: model.selection = .none; return true
        default: break
        }
        switch chars {
        case "s" where mods.contains(.option): model.splitZoomAtPlayhead(); return true
        case "s" where mods.isEmpty: model.splitClipAtPlayhead(); return true
        case "z" where shift: timeline.zoomToFit(); return true
        case "f" where mods.isEmpty: model.toggleCameraFullscreen(); return true
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
        if new.trimmingCharacters(in: .whitespaces).isEmpty { titleField.stringValue = model.project.title; return }
        model.rename(to: new)
        titleField.stringValue = model.project.title
        window?.title = model.project.title
        window?.representedURL = model.package.url
        window?.makeFirstResponder(nil)
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

    @objc private func exportClicked() {
        guard exporter == nil, let window else { NSSound.beep(); return }
        guard player.media != nil else { NSSound.beep(); return }
        player.pause()
        let p = model.project
        let panelModel = ExportPanelModel(base: CanvasLayout.baseCanvasSize(sourceSize: p.recording.pixelSize, style: p.style),
                                          duration: model.duration, hasAudio: model.hasAudio, audioMuted: p.style.audio.muted)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ExportPanelView(model: panelModel)))
        sheet.styleMask = [.titled]
        panelModel.onCancel = { [weak window, weak sheet] in if let sheet { window?.endSheet(sheet) } }
        panelModel.onExport = { [weak self, weak window, weak sheet] settings in
            if let sheet { window?.endSheet(sheet) }
            self?.startExport(settings)
        }
        window.beginSheet(sheet)
    }

    private func startExport(_ settings: ExportSettings) {
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
                guard let self else { return }
                DockProgress.end(session)
                self.dockSession = nil
                if let pw = self.progressWindow { self.window?.endSheet(pw) }
                self.progressWindow = nil
                let size = exp.outputSize
                self.exporter = nil
                switch result {
                case .success(let url):
                    Sound.play(.exportDone)
                    MediaPipeline.didFinishRecording(url: url, kind: kind, mode: .studio, pixelSize: size, scale: CGFloat(scale))
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

    // MARK: Closing

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
