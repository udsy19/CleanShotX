import AppKit
import UniformTypeIdentifiers

/// Single entry point for everything that happens after a capture finishes:
/// post-processing → write file → history → sound → configured after-capture actions.
@MainActor
public enum MediaPipeline {

    // MARK: Ingest

    /// Call with the raw screenshot pixels. Returns the created media, or nil when the user cancelled the name
    /// prompt or the pixels could not be written anywhere (they are then left on the clipboard).
    @discardableResult
    public static func didCaptureImage(_ raw: CGImage, scale: CGFloat, mode: CaptureMode,
                                       actions override: Set<AfterCaptureAction>? = nil,
                                       playSound: Bool = true) -> CapturedMedia? {
        let (image, effectiveScale) = ImageTools.applyScreenshotPreferences(raw, scale: scale)
        let actions = override ?? Defaults[.afterScreenshotActions]
        let format = Defaults[.screenshotFormat]

        guard let name = proposedName(for: mode) else { return nil }  // nil = user cancelled rename
        let fileName = (name as NSString).appendingPathExtension(format.fileExtension) ?? name
        let wantsSave = actions.contains(.save)
        // The export folder may be gone, read-only, a file, or on an unmounted volume: the capture then lands in
        // the library (still unsaved, so Quick Access / History offer Save) instead of being lost.
        var saved = false
        var url: URL?
        if wantsSave, let dir = usableExportLocation() {
            url = writeCapture(image, named: fileName, in: dir, format: format, scale: effectiveScale)
            saved = url != nil
        }
        if url == nil { url = writeCapture(image, named: fileName, in: AppPaths.media, format: format, scale: effectiveScale) }
        if wantsSave, !saved, url != nil { explainExportFallback() }
        guard let url else {
            Clipboard.copy(image: image)
            Alerts.error("Something went wrong saving your file.",
                         ExportProblem.nowhereToWrite(AppPaths.media))
            return nil
        }
        let media = CapturedMedia(url: url, kind: .image, mode: mode,
                                  pixelSize: CGSize(width: image.width, height: image.height),
                                  scale: effectiveScale, isSaved: saved)
        if playSound { Sound.play(.capture) }
        ingest(media, actions: wantsSave && !saved ? withoutFailedSave(actions) : actions)
        return media
    }

    /// Saving was already explained: don't retry it (a second alert), and show the card so the user can Save
    /// somewhere else.
    private static func withoutFailedSave(_ actions: Set<AfterCaptureAction>) -> Set<AfterCaptureAction> {
        actions.subtracting([.save]).union([.showQuickAccess])
    }

    /// Call when a recording/GIF/studio export has been written to `url`.
    @discardableResult
    public static func didFinishRecording(url: URL, kind: MediaKind, mode: CaptureMode, pixelSize: CGSize, scale: CGFloat,
                                          actions override: Set<AfterCaptureAction>? = nil) -> CapturedMedia {
        var actions = override ?? Defaults[.afterRecordingActions]
        var finalURL = url
        var saved = false
        if actions.contains(.save) {
            if let dir = usableExportLocation() {
                let dest = AppPaths.uniqueURL(dir.appendingPathComponent(url.lastPathComponent))
                do { try FileManager.default.moveItem(at: url, to: dest); finalURL = dest; saved = true }
                catch { Log.app.error("Couldn't move the recording to the export folder: \(error.localizedDescription, privacy: .public)") }
            }
            // Only a recording that really reached the export folder is "saved"; otherwise it stays in the
            // library and Quick Access / History keep offering Save.
            if !saved { explainExportFallback(); actions = withoutFailedSave(actions) }
        }
        let media = CapturedMedia(url: finalURL, kind: kind, mode: mode, pixelSize: pixelSize, scale: scale, isSaved: saved)
        if actions.isEmpty { actions = [.showQuickAccess] }
        ingest(media, actions: actions)
        return media
    }

    /// What went wrong with the export folder, in plain words.
    public enum ExportProblem: LocalizedError {
        case unusable(URL)
        case nowhereToWrite(URL)
        public var errorDescription: String? {
            switch self {
            case .unusable(let dir):
                "Couldn't save to “\((dir.path as NSString).abbreviatingWithTildeInPath)”; the capture was kept in Super Screenshot's library instead. Check the export location in Settings → General."
            case .nowhereToWrite(let dir):
                "Neither the export location nor the library folder (\((dir.path as NSString).abbreviatingWithTildeInPath)) could be written. The image was copied to the clipboard so you can paste it somewhere safe."
            }
        }
    }

    /// The configured export folder when files can be created in it, else nil.
    public static func usableExportLocation() -> URL? {
        let dir = AppPaths.exportLocation   // creates it when missing
        return AppPaths.isWritableDirectory(dir) ? dir : nil
    }

    /// Writes `image` under a unique name in `dir`. Retries with the next free name if a file appears at the
    /// chosen one (another capture landing in the same second), never replacing anything. Nil = `dir` unusable.
    public static func writeCapture(_ image: CGImage, named fileName: String, in dir: URL, format: ImageFormat, scale: CGFloat) -> URL? {
        for _ in 0..<8 {
            let url = AppPaths.uniqueURL(dir.appendingPathComponent(fileName))
            do {
                try ImageTools.write(image, to: url, format: format, scale: scale, replacing: false)
                return url
            } catch ImageError.fileExists {
                continue
            } catch {
                Log.app.error("Couldn't write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    private static func explainExportFallback() {
        Alerts.error("Couldn't save to the export location.", ExportProblem.unusable(AppPaths.exportLocation))
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
            guard let dir = usableExportLocation() else {
                // The file stays where it is (still unsaved, still in Quick Access / History).
                Alerts.error("Couldn't save to the export location.", ExportProblem.unusable(AppPaths.exportLocation))
                return nil
            }
            dest = AppPaths.uniqueURL(dir.appendingPathComponent(media.url.lastPathComponent))
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
    /// at launch (no window can still reference them across a relaunch). A card closed without saving therefore
    /// stays restorable for the whole session and for a day after. Only at launch, only plain files, never
    /// anything newer than `age`.
    public static func sweepOrphanedMedia(olderThan age: TimeInterval = 86_400) {
        guard !Defaults[.historyEnabled] else { return }
        sweep(AppPaths.media, olderThan: age, now: Date())
    }

    /// Deletes the plain files in `dir` whose modification date is older than `age` seconds before `now`.
    public static func sweep(_ dir: URL, olderThan age: TimeInterval, now: Date) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-age)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        for f in files {
            guard let values = try? f.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate, date < cutoff else { continue }
            try? fm.removeItem(at: f)
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
            // The encoded file bytes go straight on the pasteboard: no decode, however large the capture.
            item.setData(data, forType: type)
            // A PNG flavour for apps that don't take JPEG/HEIC/TIFF, rendered only if something asks for it.
            if type != .png { item.setDataProvider(LazyPNGProvider(url: media.url), forTypes: [.png]) }
            if mode == .fileAndImage { item.setString(media.url.absoluteString, forType: .fileURL) }
            items.append(item)
        } else {
            items.append(media.url as NSURL)
        }
        pb.writeObjects(items)
    }

    /// Re-encodes an image file as PNG when a pasteboard consumer requests that flavour.
    private final class LazyPNGProvider: NSObject, NSPasteboardItemDataProvider {
        let url: URL
        init(url: URL) { self.url = url }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .png, let cg = ImageTools.load(url), let png = ImageTools.pngData(cg) else { return }
            item.setData(png, forType: .png)
        }
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
