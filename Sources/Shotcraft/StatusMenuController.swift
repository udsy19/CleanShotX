import AppKit
import Combine
import ShotcraftCore

/// Menu bar icon + menu. Turns into a stop button with elapsed time while recording.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var recording = false
    private var progress: Double?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        menu.delegate = self
        Defaults.publisher(.showMenuBarIcon).sink { [weak self] show in self?.setVisible(show) }.store(in: &cancellables)
        StatusBar.setRecording = { [weak self] active, elapsed in self?.setRecording(active, elapsed: elapsed) }
        StatusBar.setProgress = { [weak self] p in self?.progress = p; self?.updateIcon() }
        rebuild()
    }

    private func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.button?.target = self
            i.button?.action = #selector(statusItemClicked)
            i.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item = i
            updateIcon()
        } else if !visible, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    private func updateIcon() {
        guard let button = item?.button else { return }
        if recording {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            button.contentTintColor = .systemRed
        } else {
            let name = progress != nil ? "icloud.and.arrow.up" : "camera.aperture"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Shotcraft")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.title = progress.map { " \(Int($0 * 100))%" } ?? ""
            button.imagePosition = .imageLeading
        }
    }

    private func setRecording(_ active: Bool, elapsed: String?) {
        recording = active
        updateIcon()
        item?.button?.title = active && Defaults[.recordShowTimeInMenuBar] ? " \(elapsed ?? "")" : ""
        item?.button?.imagePosition = .imageLeading
    }

    @objc private func statusItemClicked() {
        if recording { ActionRouter.stopAnyRecording(); return }
        guard let button = item?.button else { return }
        rebuild()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func rebuild() {
        menu.removeAllItems()
        add(.allInOne)
        menu.addItem(.separator())
        add(.captureArea); add(.capturePreviousArea); add(.captureFullscreen); add(.captureWindow); add(.selfTimer)
        add(.scrollingCapture); add(.captureText)
        menu.addItem(.separator())
        add(.recordScreen); add(.recordGIF); add(.recordStudio)
        menu.addItem(.separator())

        let annotate = NSMenu()
        for a: AppAction in [.openAnnotate, .openFromClipboard, .annotateLast] { annotate.addItem(makeItem(a)) }
        submenu("Annotate", annotate, symbol: "pencil.tip.crop.circle")

        let pins = NSMenu()
        for a: AppAction in [.pinScreenshot, .pinLast, .togglePins, .closeAllOverlays] { pins.addItem(makeItem(a)) }
        submenu("Pin & Overlays", pins, symbol: "pin")

        let more = NSMenu()
        for a: AppAction in [.captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .captureAreaAndUpload, .captureAreaAndPin, .colorPicker] {
            more.addItem(makeItem(a))
        }
        submenu("More Capture Options", more, symbol: "ellipsis.circle")
        menu.addItem(.separator())

        add(.openHistory); add(.restoreLastCapture)
        addUploadItems()
        let icons = makeItem(.toggleDesktopIcons)
        icons.title = Services.capture?.desktopIconsHidden == true ? "Show Desktop Icons" : "Hide Desktop Icons"
        menu.addItem(icons)
        menu.addItem(.separator())
        add(.openPreferences)
        let quit = NSMenuItem(title: "Quit Shotcraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func add(_ a: AppAction) { menu.addItem(makeItem(a)) }

    /// "Cancel Upload" while uploading, plus the three most recent upload links (click copies the link).
    private func addUploadItems() {
        guard let upload = Services.upload else { return }
        if upload.isUploading {
            let cancel = NSMenuItem(title: "Cancel Upload", action: #selector(cancelUploads), keyEquivalent: "")
            cancel.target = self
            cancel.image = NSImage(systemSymbolName: "xmark.icloud", accessibilityDescription: nil)
            menu.addItem(cancel)
        }
        let recent = upload.recentUploads.prefix(3)
        guard !recent.isEmpty else { return }
        let sub = NSMenu()
        for r in recent {
            let i = NSMenuItem(title: r.fileName, action: #selector(copyUploadLink(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = r.url
            i.toolTip = r.url.absoluteString
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let all = NSMenuItem(title: "View All Uploads…", action: #selector(viewAllUploads), keyEquivalent: "")
        all.target = self
        sub.addItem(all)
        submenu("Recent Uploads", sub, symbol: "icloud")
    }

    @objc private func cancelUploads() { Services.upload.cancelAll() }
    @objc private func copyUploadLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Clipboard.copy(url: url)
        HUD.show("Link has been copied")
    }
    @objc private func viewAllUploads() { Services.preferences.show(pane: "upload") }

    private func submenu(_ title: String, _ sub: NSMenu, symbol: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        i.submenu = sub
        menu.addItem(i)
    }

    private func makeItem(_ a: AppAction) -> NSMenuItem {
        let i = NSMenuItem(title: a.title, action: #selector(run(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = a.rawValue
        if let s = a.shortcut, !s.keyEquivalent.isEmpty {
            i.keyEquivalent = s.keyEquivalent
            i.keyEquivalentModifierMask = s.modifiers
        }
        i.image = NSImage(systemSymbolName: symbol(for: a), accessibilityDescription: nil)
        return i
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = AppAction(rawValue: raw) else { return }
        // Let the menu close before overlays appear so it isn't captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ActionRouter.perform(a) }
    }

    private func symbol(for a: AppAction) -> String {
        switch a {
        case .allInOne: "square.dashed.inset.filled"
        case .captureArea, .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .captureAreaAndUpload, .captureAreaAndPin: "plus.viewfinder"
        case .capturePreviousArea: "arrow.counterclockwise.circle"
        case .captureFullscreen: "macwindow.on.rectangle"
        case .captureWindow: "macwindow"
        case .selfTimer: "timer"
        case .scrollingCapture: "arrow.up.and.down.text.horizontal"
        case .captureText: "text.viewfinder"
        case .recordScreen: "record.circle"
        case .recordGIF: "photo.stack"
        case .recordStudio: "video.badge.waveform"
        case .toggleDesktopIcons: "menubar.dock.rectangle"
        case .openAnnotate, .annotateLast: "pencil.tip.crop.circle"
        case .openFromClipboard: "doc.on.clipboard"
        case .pinScreenshot, .pinLast: "pin"
        case .togglePins: "eye"
        case .closeAllOverlays: "xmark.square"
        case .openHistory: "clock.arrow.circlepath"
        case .restoreLastCapture: "arrow.uturn.backward.circle"
        case .colorPicker: "eyedropper"
        case .openPreferences: "gearshape"
        }
    }
}
