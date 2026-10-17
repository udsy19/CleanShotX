import AppKit
import Quartz
import ShotcraftCore

/// Actions shared by Quick Access cards, pins and the history window. Cross-module work goes through `Services`.
@MainActor
enum MediaActions {
    static func copy(_ media: CapturedMedia) {
        Clipboard.copy(media)
    }

    /// Saves per the Quick Access "Save" preference (or always asks when `forceAsk`). Returns true on success.
    @discardableResult
    static func save(_ media: CapturedMedia, forceAsk: Bool = false) -> Bool {
        let ask = forceAsk || Defaults[.quickAccessSaveBehavior] == .askForDestination
        return MediaPipeline.save(media, askForDestination: ask) != nil
    }

    /// Images → Annotate; videos/GIFs → Video Editor; Studio projects → Studio editor.
    static func edit(_ media: CapturedMedia) {
        switch media.kind {
        case .image: Services.annotate?.open(media)
        case .video, .gif: Services.recording?.openVideoEditor(media)
        case .studioProject: Services.studio?.openProject(media.url)
        }
    }

    static func editTitle(for media: CapturedMedia) -> String {
        media.isImage ? "Open Annotate tool (⌘A)" : "Open Video Editor (⌘A)"
    }

    static func pin(_ media: CapturedMedia) {
        guard media.isImage else { NSSound.beep(); return }
        Services.pin?.pin(media)
    }

    static var canUpload: Bool { Services.upload?.isConfigured ?? false }

    /// Starts an upload. When no destination is configured, explains and offers to open Settings.
    static func upload(_ media: CapturedMedia, progress: ((Double) -> Void)?, completion: ((Result<URL, Error>) -> Void)?) {
        guard let up = Services.upload, up.isConfigured else {
            if Alerts.confirm(UploadError.notConfigured.localizedDescription, confirmTitle: "Open Settings") {
                Services.preferences?.show(pane: "upload")
            }
            completion?(.failure(UploadError.notConfigured))
            return
        }
        up.upload(media, progress: progress) { result in
            if case .success(let link) = result, media.uploadedURL != link {
                media.uploadedURL = link
                media.notifyChanged()
            }
            completion?(result)
        }
    }

    static func open(_ media: CapturedMedia) {
        if media.kind == .studioProject { Services.studio?.openProject(media.url); return }
        NSWorkspace.shared.open(media.url)
    }

    static func showInFinder(_ media: CapturedMedia) {
        NSWorkspace.shared.activateFileViewerSelecting([media.url])
    }

    /// Prompts for a new file name (extension preserved) and renames in place.
    @discardableResult
    static func rename(_ media: CapturedMedia) -> Bool {
        let stem = media.url.deletingPathExtension().lastPathComponent
        guard let name = Alerts.prompt(title: "Rename", message: "Enter a new name for the file.", defaultValue: stem) else { return false }
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty, clean != stem else { return false }
        let ext = media.url.pathExtension
        let dest = media.url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? clean : "\(clean).\(ext)")
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            Alerts.error("A file named “\(dest.lastPathComponent)” already exists.")
            return false
        }
        do {
            try FileManager.default.moveItem(at: media.url, to: dest)
            media.url = dest
            media.notifyChanged()
            return true
        } catch {
            Alerts.error("Couldn't rename the file.", error)
            return false
        }
    }

    /// Moves the file to the Trash and removes it from every overlay and from history.
    @discardableResult
    static func moveToTrash(_ media: CapturedMedia) -> Bool {
        do {
            try FileManager.default.trashItem(at: media.url, resultingItemURL: nil)
        } catch {
            Alerts.error("Couldn't move the file to the Trash.", error)
            return false
        }
        QuickAccessController.shared.removeWithoutRestore(media)
        PinController.shared.close(mediaID: media.id)
        HistoryStore.shared.remove(id: media.id)
        return true
    }

    /// Runs OCR on the image and copies the text.
    static func copyText(from image: CGImage) {
        guard let text = Services.text else { NSSound.beep(); return }
        text.recognizeText(in: image, keepLineBreaks: Defaults[.ocrKeepLineBreaks]) { result in
            guard !result.isEmpty else { HUD.show("No text found", symbol: "text.viewfinder"); return }
            Clipboard.copy(text: result)
            Sound.play(.textCopied)
            HUD.show("Text has been copied", symbol: "text.viewfinder")
        }
    }

    /// Writes an image to a temporary PNG (for dragging pins that have no backing file).
    static func temporaryFile(for image: NSImage, name: String = "Pinned Image") -> URL? {
        guard let cg = image.cgImage, let data = ImageTools.pngData(cg) else { return nil }
        let url = AppPaths.uniqueURL(AppPaths.temporary.appendingPathComponent(name).appendingPathExtension("png"))
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}

// MARK: - Quick Look

/// In-app Quick Look panel built on `QLPreviewView` (our overlays never become key, so the shared
/// `QLPreviewPanel` can't find a controller in the responder chain).
@MainActor
final class QuickLookController: NSObject, NSWindowDelegate {
    static let shared = QuickLookController()
    private var panel: NSPanel?
    private var previewView: QLPreviewView?
    private(set) var currentURL: URL?
    private var keyMonitor: Any?

    var isShowing: Bool { panel?.isVisible ?? false }

    func toggle(_ url: URL, pointSize: CGSize) {
        if isShowing, currentURL == url { close() } else { show(url, pointSize: pointSize) }
    }

    func show(_ url: URL, pointSize: CGSize) {
        let screen = NSScreen.active
        let vis = screen.visibleFrame
        var size = pointSize == .zero ? CGSize(width: 800, height: 600) : pointSize
        let fit = min(1, vis.width * 0.7 / size.width, vis.height * 0.7 / size.height)
        size = CGSize(width: max(320, size.width * fit), height: max(240, size.height * fit + 28))
        let frame = NSRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2, width: size.width, height: size.height)

        let p: NSPanel
        if let existing = panel { p = existing; p.setFrame(frame, display: true) } else {
            p = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.level = OverlayWindow.quickAccessLevel
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.delegate = self
            let v = QLPreviewView(frame: NSRect(origin: .zero, size: frame.size), style: .normal)!
            v.autoresizingMask = [.width, .height]
            v.shouldCloseWithWindow = false
            p.contentView = v
            previewView = v
            panel = p
        }
        p.title = url.lastPathComponent
        previewView?.previewItem = url as NSURL
        currentURL = url
        p.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        panel?.orderOut(nil)
        previewView?.previewItem = nil
        currentURL = nil
        removeKeyMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        previewView?.previewItem = nil
        currentURL = nil
        removeKeyMonitor()
    }

    /// Space / Esc close the preview while it is key.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == UInt16(Keys.space) || event.keyCode == UInt16(Keys.escape) {
                self.close()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}
