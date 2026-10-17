import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import ShotcraftCore

/// `AnnotateServicing` implementation: opens editor windows and keeps them alive while open
/// (CleanShot `AnnotateController(projectsHistory, annotates)`).
@MainActor
public final class AnnotateService: AnnotateServicing {
    public static let shared = AnnotateService()

    private var editors: [AnnotateEditorController] = []
    private var cancellables = Set<AnyCancellable>()

    private init() {
        Defaults.publisher(.annotateAlwaysOnTop).dropFirst().receive(on: DispatchQueue.main).sink { [weak self] onTop in
            self?.editors.forEach { $0.window?.level = onTop ? .floating : .normal }
        }.store(in: &cancellables)
        Defaults.publisher(.annotateShowDockIcon).dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateActivationPolicy()
        }.store(in: &cancellables)
    }

    /// UTType for `.shotcraft` projects that works whether or not the app bundle declares it.
    public nonisolated static var projectType: UTType {
        UTType(ShotcraftDocument.typeIdentifier)
            ?? UTType(filenameExtension: ShotcraftDocument.fileExtension, conformingTo: .data) ?? .data
    }

    // MARK: AnnotateServicing

    public func open(_ media: CapturedMedia) {
        guard media.isImage else { return }
        if let existing = editors.first(where: { $0.media == media }) { focus(existing); return }
        // Resume an earlier edit of this capture if its project is still in sync with the file.
        if let p = media.projectURL, let loaded = Self.loadSidecar(p, for: media.url) {
            present(AnnotateEditorController(state: loaded.state, origin: .media, media: media, projectURL: nil, createdAt: loaded.createdAt))
            return
        }
        guard let img = ImageTools.load(media.url) else {
            Alerts.error("The image couldn't be opened.", CocoaError(.fileReadCorruptFile))
            return
        }
        var scale = media.scale > 0 ? media.scale : 1
        if media.pixelSize.width > 0, CGFloat(img.width) != media.pixelSize.width { scale = Self.scale(of: media.url, image: img) }
        present(AnnotateEditorController(state: CanvasState(image: img, scale: scale), origin: .media, media: media, projectURL: nil))
    }

    public func open(fileURL: URL) {
        if fileURL.pathExtension.lowercased() == ShotcraftDocument.fileExtension { openDocument(fileURL); return }
        if let existing = editors.first(where: { $0.media?.url.standardizedFileURL == fileURL.standardizedFileURL }) { focus(existing); return }
        guard let img = ImageTools.load(fileURL) else {
            Alerts.error("The file couldn't be opened because it isn't an image.")
            return
        }
        let scale = Self.scale(of: fileURL, image: img)
        let media = CapturedMedia(url: fileURL, kind: .image, mode: .imported,
                                  pixelSize: CGSize(width: img.width, height: img.height), scale: scale, isSaved: true)
        present(AnnotateEditorController(state: CanvasState(image: img, scale: scale), origin: .media, media: media, projectURL: nil))
    }

    public func openFromClipboard() {
        guard let image = Clipboard.image(), let best = image.bestCGImage else {
            NSSound.beep()
            HUD.show("No image on the clipboard", symbol: "exclamationmark.circle.fill")
            return
        }
        present(AnnotateEditorController(state: CanvasState(image: best.image, scale: best.scale), origin: .clipboard, media: nil, projectURL: nil))
    }

    public func openDocument(_ url: URL) {
        if let existing = editors.first(where: { $0.projectURL?.standardizedFileURL == url.standardizedFileURL }) { focus(existing); return }
        do {
            let loaded = try ShotcraftDocument.decode(Data(contentsOf: url))
            RecentProjects.add(url)
            present(AnnotateEditorController(state: loaded.state, origin: .project, media: nil, projectURL: url, createdAt: loaded.createdAt))
        } catch {
            Alerts.error("An error occurred while opening the project", error)
        }
    }

    public func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, Self.projectType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose an image or a Shotcraft project to annotate"
        panel.prompt = "Annotate"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(fileURL: url) }
    }

    // MARK: Window management

    private func present(_ editor: AnnotateEditorController) {
        editor.onClose = { [weak self] e in
            guard let self else { return }
            self.editors.removeAll { $0 === e }
            // Defer so the closing window is gone before deciding about the Dock icon.
            DispatchQueue.main.async { self.updateActivationPolicy() }
        }
        editors.append(editor)
        updateActivationPolicy()
        editor.present()
    }

    private func focus(_ editor: AnnotateEditorController) {
        NSApp.activate(ignoringOtherApps: true)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    /// Shows the Dock icon while any editor is open (Settings → Annotate → "Show Dock icon").
    private func updateActivationPolicy() {
        DockIcon.set("annotate", count: Defaults[.annotateShowDockIcon] ? editors.count : 0)
    }

    // MARK: Helpers

    /// Pixels per point of an image file: `@2x` suffix, else DPI metadata (144 dpi = 2×), else 1.
    static func scale(of url: URL, image: CGImage) -> CGFloat {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix("@3x") { return 3 }
        if name.hasSuffix("@2x") { return 2 }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi > 72 {
            return CGFloat(max(1, min(3, (dpi / 72).rounded())))
        }
        return 1
    }

    /// Loads a capture's sidecar project when it still matches the image file (same source, not older).
    static func loadSidecar(_ project: URL, for imageURL: URL) -> ShotcraftDocument.Loaded? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: project.path), let data = try? Data(contentsOf: project),
              let loaded = try? ShotcraftDocument.decode(data) else { return nil }
        if let src = loaded.sourceURL, src.standardizedFileURL != imageURL.standardizedFileURL { return nil }
        let projectDate = (try? fm.attributesOfItem(atPath: project.path)[.modificationDate] as? Date) ?? .distantPast
        let imageDate = (try? fm.attributesOfItem(atPath: imageURL.path)[.modificationDate] as? Date) ?? .distantPast
        return projectDate.addingTimeInterval(5) >= imageDate ? loaded : nil
    }
}
