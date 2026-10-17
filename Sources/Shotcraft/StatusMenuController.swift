import AppKit
import Combine
import ShotcraftCore

/// Menu bar icon + menu (item order and wording follow CleanShot X 5.0, see docs/specs/ui-reference.md §1).
/// Turns into a stop button with elapsed time while recording; accepts images dropped onto the icon.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
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
            // Attached the standard way so macOS positions the menu under the icon. While recording the menu is
            // detached and a click stops the recording instead (`setRecording`).
            i.menu = recording ? nil : menu
            i.button?.target = self
            i.button?.action = #selector(stopRecordingClicked)
            i.button?.window?.registerForDraggedTypes([.fileURL])
            i.button?.window?.delegate = self
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
            button.toolTip = "Press to stop recording"
        } else {
            button.image = progress != nil
                ? NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "Uploading")
                : Self.menuBarGlyph
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.toolTip = "Shotcraft"
            button.title = progress.map { " \(Int($0 * 100))%" } ?? ""
            button.imagePosition = .imageLeading
        }
    }

    /// Template glyph matching the app icon: viewfinder corners around a solid capture dot.
    private static let menuBarGlyph: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let f = r.insetBy(dx: 2, dy: 2), arm: CGFloat = 4.2
            let p = NSBezierPath()
            p.lineWidth = 1.7; p.lineCapStyle = .round; p.lineJoinStyle = .round
            for (cx, cy, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
                p.move(to: NSPoint(x: cx, y: cy + dy * arm)); p.line(to: NSPoint(x: cx, y: cy)); p.line(to: NSPoint(x: cx + dx * arm, y: cy))
            }
            NSColor.black.setStroke(); p.stroke()
            let d: CGFloat = 4.4
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Shotcraft"
        return img
    }()

    private func setRecording(_ active: Bool, elapsed: String?) {
        recording = active
        item?.menu = active ? nil : menu
        updateIcon()
        item?.button?.title = active && Defaults[.recordShowTimeInMenuBar] ? " \(elapsed ?? "")" : ""
        item?.button?.imagePosition = .imageLeading
    }

    @objc private func stopRecordingClicked() {
        if recording { ActionRouter.stopAnyRecording() }
    }

    /// Rebuilt right before it opens so titles (desktop icons, uploads) and shortcuts are current.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func rebuild() {
        menu.removeAllItems()
        add(.allInOne, symbol: "1.circle")
        add(.captureArea, symbol: "viewfinder")
        add(.captureFullscreen, symbol: "display")
        add(.captureWindow, symbol: "macwindow")
        add(.scrollingCapture, symbol: "arrow.down")
        add(.selfTimer, symbol: "timer")
        add(.captureText, title: "Capture Text (OCR)", symbol: "textformat")
        add(.recordScreen, symbol: "video")
        menu.addItem(.separator())

        let hidden = Services.capture?.desktopIconsHidden == true
        add(.toggleDesktopIcons, title: hidden ? "Show Desktop Icons" : "Hide Desktop Icons", symbol: hidden ? "eye" : "eye.slash")
        menu.addItem(.separator())

        add(.openAnnotate, title: "Open…", symbol: "pencil")
        add(.pinScreenshot, title: "Pin to the Screen…", symbol: "pin")
        menu.addItem(.separator())

        add(.openHistory, title: "Capture History…", symbol: "clock.arrow.circlepath")
        addUploadItems()
        menu.addItem(.separator())

        plain("About Shotcraft…", #selector(showAbout))
        plain("Settings…", #selector(showSettings)).keyEquivalent = ","
        menu.addItem(.separator())
        plain("Quit", #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    @discardableResult
    private func add(_ a: AppAction, title: String? = nil, symbol: String) -> NSMenuItem {
        let i = NSMenuItem(title: title ?? a.title, action: #selector(run(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = a.rawValue
        if let s = a.shortcut, !s.keyEquivalent.isEmpty {
            i.keyEquivalent = s.keyEquivalent
            i.keyEquivalentModifierMask = s.modifiers
        }
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(i)
        return i
    }

    @discardableResult
    private func plain(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = target ?? self
        menu.addItem(i)
        return i
    }

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
        let parent = NSMenuItem(title: "Recent Uploads", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: nil)
        parent.submenu = sub
        menu.addItem(parent)
    }

    @objc private func cancelUploads() { Services.upload.cancelAll() }
    @objc private func copyUploadLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Clipboard.copy(url: url)
        HUD.show("Link has been copied")
    }
    @objc private func viewAllUploads() { Services.preferences.show(pane: "upload") }
    @objc private func showAbout() { Services.preferences.show(pane: "about") }
    @objc private func showSettings() { Services.preferences.show(pane: nil) }

    @objc private func run(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = AppAction(rawValue: raw) else { return }
        // Let the menu close before overlays appear so it isn't captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ActionRouter.perform(a) }
    }

    // MARK: - Drop images on the menu bar icon → Annotate (hold ⌥ to pin)

    private func droppedImages(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { NSImage(contentsOf: $0) != nil }
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImages(sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedImages(sender)
        let pin = NSEvent.modifierFlags.contains(.option)
        for u in urls {
            if pin, let img = NSImage(contentsOf: u) { Services.pin.pin(image: img, sourceURL: u) }
            else { Services.annotate.open(fileURL: u) }
        }
        return !urls.isEmpty
    }
}
