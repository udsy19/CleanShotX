import AppKit
import UniformTypeIdentifiers

/// Single entry point for everything that happens after a capture finishes:
/// post-processing → write file → history → sound → configured after-capture actions.
@MainActor
public enum MediaPipeline {

    // MARK: Ingest

    /// Call with the raw screenshot pixels. Returns the created media (nil if writing failed).
    @discardableResult
    public static func didCaptureImage(_ raw: CGImage, scale: CGFloat, mode: CaptureMode,
                                       actions override: Set<AfterCaptureAction>? = nil,
                                       playSound: Bool = true, from rect: CGRect? = nil) -> CapturedMedia? {
        let (image, effectiveScale) = ImageTools.applyScreenshotPreferences(raw, scale: scale)
        let actions = override ?? Defaults[.afterScreenshotActions]
        let format = Defaults[.screenshotFormat]

        guard let name = proposedName(for: mode) else { return nil }  // nil = user cancelled rename
        let saveNow = actions.contains(.save)
        let dir = saveNow ? AppPaths.exportLocation : AppPaths.media
        let url = AppPaths.uniqueURL(dir.appendingPathComponent(name).appendingPathExtension(format.fileExtension))
        do { try ImageTools.write(image, to: url, format: format, scale: effectiveScale) } catch {
            Alerts.error("Something went wrong saving your file.", error); return nil
        }
        let media = CapturedMedia(url: url, kind: .image, mode: mode,
                                  pixelSize: CGSize(width: image.width, height: image.height),
                                  scale: effectiveScale, isSaved: saveNow)
        media.captureRect = rect
        if playSound { Sound.play(.capture) }
        ingest(media, actions: actions)
        return media
    }

    /// Call when a recording/GIF/studio export has been written to `url`.
    @discardableResult
    public static func didFinishRecording(url: URL, kind: MediaKind, mode: CaptureMode, pixelSize: CGSize, scale: CGFloat,
                                          actions override: Set<AfterCaptureAction>? = nil) -> CapturedMedia {
        var actions = override ?? Defaults[.afterRecordingActions]
        var finalURL = url
        if actions.contains(.save) {
            let dest = AppPaths.uniqueURL(AppPaths.exportLocation.appendingPathComponent(url.lastPathComponent))
            if (try? FileManager.default.moveItem(at: url, to: dest)) != nil { finalURL = dest }
        }
        let media = CapturedMedia(url: finalURL, kind: kind, mode: mode, pixelSize: pixelSize, scale: scale,
                                  isSaved: actions.contains(.save))
        if actions.isEmpty { actions = [.showQuickAccess] }
        ingest(media, actions: actions)
        return media
    }

    /// Adds already-existing media (e.g. dropped/opened files) to the normal flow.
    public static func ingest(_ media: CapturedMedia, actions: Set<AfterCaptureAction>) {
        if Defaults[.historyEnabled] { Services.history?.add(media) }
        // Order matters: copy first so the clipboard is ready even if a window steals focus.
        let order: [AfterCaptureAction] = [.copyToClipboard, .save, .upload, .showQuickAccess, .pin, .annotate, .openVideoEditor]
        for action in order where actions.contains(action) {
            if action == .save && media.isSaved { continue }
            perform(action, on: media)
        }
    }

    // MARK: Actions

    public static func perform(_ action: AfterCaptureAction, on media: CapturedMedia) {
        switch action {
        case .showQuickAccess: Services.quickAccess?.show(media)
        case .copyToClipboard: Clipboard.copy(media)
        case .save: save(media, askForDestination: false)
        case .annotate:
            if media.isImage { Services.annotate?.open(media) } else { Services.recording?.openVideoEditor(media) }
        case .upload: Services.upload?.upload(media, progress: nil, completion: nil)
        case .pin: if media.isImage { Services.pin?.pin(media) }
        case .openVideoEditor:
            if media.isVideoLike { Services.recording?.openVideoEditor(media) }
        }
    }

    /// Moves/copies the media into the export location (or a user-chosen location). Returns the new URL.
    @discardableResult
    public static func save(_ media: CapturedMedia, askForDestination: Bool) -> URL? {
        var dest: URL
        if askForDestination {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = media.url.lastPathComponent
            panel.directoryURL = AppPaths.exportLocation
            if let type = UTType(filenameExtension: media.url.pathExtension) { panel.allowedContentTypes = [type] }
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let u = panel.url else { return nil }
            dest = u
            try? FileManager.default.removeItem(at: dest)
        } else {
            if media.isSaved && media.url.deletingLastPathComponent().standardizedFileURL == AppPaths.exportLocation.standardizedFileURL {
                return media.url
            }
            dest = AppPaths.uniqueURL(AppPaths.exportLocation.appendingPathComponent(media.url.lastPathComponent))
        }
        do {
            let inMediaDir = media.url.path.hasPrefix(AppPaths.media.path) || media.url.path.hasPrefix(AppPaths.recordings.path)
            if inMediaDir { try FileManager.default.moveItem(at: media.url, to: dest) }
            else { try FileManager.default.copyItem(at: media.url, to: dest) }
            media.url = dest
            media.isSaved = true
            media.notifyChanged()
            return dest
        } catch {
            Alerts.error("Something went wrong saving your file.", error)
            return nil
        }
    }

    /// With History disabled nothing indexes unsaved captures in `AppPaths.media`; delete ones older than a day
    /// at launch (no window can still reference them across a relaunch).
    public static func sweepOrphanedMedia(olderThan age: TimeInterval = 86_400) {
        guard !Defaults[.historyEnabled] else { return }
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        let files = (try? fm.contentsOfDirectory(at: AppPaths.media, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if date < cutoff { try? fm.removeItem(at: f) }
        }
    }

    // MARK: Naming

    /// Template-rendered name; when "Ask for name after every capture" is on, prompts the user.
    static func proposedName(for mode: CaptureMode) -> String? {
        let name = FileNameTemplate.render(Defaults[.fileNameTemplate], kind: mode.fileNameKind)
        guard Defaults[.askForNameAfterCapture] else { return name }
        return Alerts.prompt(title: "Name your capture", defaultValue: name)
    }
}

/// Clipboard writes honoring the "Clipboard content" preference.
@MainActor
public enum Clipboard {
    public static func copy(_ media: CapturedMedia) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let mode = Defaults[.clipboardContent]
        var items: [NSPasteboardWriting] = []
        if media.isImage && mode != .fileOnly, let data = try? Data(contentsOf: media.url) {
            let item = NSPasteboardItem()
            let type = NSPasteboard.PasteboardType(UTType(filenameExtension: media.url.pathExtension)?.identifier ?? "public.png")
            item.setData(data, forType: type)
            if type != .png, let cg = ImageTools.load(media.url), let png = ImageTools.pngData(cg) { item.setData(png, forType: .png) }
            if mode == .fileAndImage { item.setString(media.url.absoluteString, forType: .fileURL) }
            items.append(item)
        } else {
            items.append(media.url as NSURL)
        }
        pb.writeObjects(items)
    }

    public static func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public static func copy(image: CGImage) {
        NSPasteboard.general.clearContents()
        if let png = ImageTools.pngData(image) { NSPasteboard.general.setData(png, forType: .png) }
    }

    public static func copy(url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// An image on the clipboard (image data or an image file reference).
    public static func image() -> NSImage? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first, let img = NSImage(contentsOf: u) { return img }
        return NSImage(pasteboard: pb)
    }
}
