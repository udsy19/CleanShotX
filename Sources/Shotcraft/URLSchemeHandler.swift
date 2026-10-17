import AppKit
import ShotcraftCore

/// `shotcraft://<command>?<params>` — command names and parameters mirror CleanShot X's public URL scheme API
/// so existing automations (Raycast, Alfred, Shortcuts) can be pointed at Shotcraft by swapping the scheme.
///
/// Coordinates (`x`, `y`, `width`, `height`) are in points with the origin at the bottom-left of the display;
/// `display` is 1-based (1 = main display). `action` is one of copy | save | annotate | upload | pin.
@MainActor
enum URLSchemeHandler {
    static func handle(_ url: URL) {
        guard let command = url.host?.lowercased() else { return }
        let q = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .map { ($0.name.lowercased(), $0.value ?? "") } ?? [], uniquingKeysWith: { $1 })

        // Commands that never read the screen (they only open files/windows the user chose) skip the API gate;
        // the share extensions rely on this.
        let harmless: Set<String> = ["open-settings", "open-history", "open-annotate", "pin", "open-from-clipboard",
                                     "add-quick-access-overlay", "restore-recently-closed", "close-all-overlays"]
        if !harmless.contains(command) && !authorize() { return }

        let rect = rectParam(q)
        let options = CaptureOptions(actions: actionParam(q), rect: rect, displayIndex: q["display"].flatMap(Int.init).map { $0 - 1 })

        switch command {
        case "all-in-one": Services.capture.allInOne()
        case "capture-area": Services.capture.captureArea(options)
        case "capture-previous-area": Services.capture.capturePreviousArea(options)
        case "capture-fullscreen": Services.capture.captureFullscreen(options)
        case "capture-window": Services.capture.captureWindow(options)
        case "self-timer": Services.capture.selfTimer(options)
        case "scrolling-capture": Services.text.startScrollingCapture(options)
        case "capture-text":
            Services.text.captureText(keepLineBreaks: q["linebreaks"].map { $0 != "false" })
        case "record-screen", "record-video": Services.recording.startRecording(.video, rect: rect)
        case "record-gif": Services.recording.startRecording(.gif, rect: rect)
        case "record-studio": Services.studio.startStudioRecording(rect: rect)
        case "stop-recording": ActionRouter.stopAnyRecording()
        case "open-annotate":
            if let path = q["filepath"] { Services.annotate.open(fileURL: URL(fileURLWithPath: path)) }
            else { Services.annotate.openWithPanel() }
        case "open-from-clipboard": Services.annotate.openFromClipboard()
        case "pin":
            if let path = q["filepath"], let img = NSImage(contentsOfFile: path) {
                Services.pin.pin(image: img, sourceURL: URL(fileURLWithPath: path))
            } else { Services.pin.pinWithPanel() }
        case "add-quick-access-overlay":
            guard let path = q["filepath"] else { return }
            let fileURL = URL(fileURLWithPath: path)
            let isVideo = ["mp4", "mov", "m4v"].contains(fileURL.pathExtension.lowercased())
            let size = NSImage(contentsOf: fileURL)?.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? .zero
            let media = CapturedMedia(url: fileURL, kind: isVideo ? .video : .image, mode: .imported,
                                      pixelSize: size, scale: 1, isSaved: true)
            Services.quickAccess.show(media)
        case "toggle-desktop-icons": Services.capture.setDesktopIconsHidden(!Services.capture.desktopIconsHidden)
        case "hide-desktop-icons": Services.capture.setDesktopIconsHidden(true)
        case "show-desktop-icons": Services.capture.setDesktopIconsHidden(false)
        case "pick-color": Services.capture.pickColor()
        case "open-history": Services.history.showWindow()
        case "restore-recently-closed": Services.history.restoreLast()
        case "open-settings": Services.preferences.show(pane: q["tab"])
        case "close-all-overlays": Services.quickAccess.closeAll(); Services.pin.closeAll()
        default:
            Log.app.info("Unknown URL command \(command, privacy: .public)")
        }
    }

    /// "Allow URL scheme API" gate; the first unapproved call asks the user.
    private static func authorize() -> Bool {
        if Defaults[.allowURLSchemeAPI] { return true }
        let ok = Alerts.confirm("An external application wants to control Shotcraft",
                                info: "Allow apps to capture your screen through the shotcraft:// URL scheme? You can change this later in Settings → Advanced.",
                                confirmTitle: "Allow", cancelTitle: "Don't Allow")
        if ok { Defaults[.allowURLSchemeAPI] = true }
        return ok
    }

    private static func actionParam(_ q: [String: String]) -> Set<AfterCaptureAction>? {
        switch q["action"]?.lowercased() {
        case "copy": [.copyToClipboard]
        case "save": [.save]
        case "annotate": [.annotate]
        case "upload": [.upload, .showQuickAccess]
        case "pin": [.pin]
        default: nil
        }
    }

    /// Converts display-relative (bottom-left origin) params to global Cocoa coordinates.
    private static func rectParam(_ q: [String: String]) -> CGRect? {
        guard let x = q["x"].flatMap(Double.init), let y = q["y"].flatMap(Double.init),
              let w = q["width"].flatMap(Double.init), let h = q["height"].flatMap(Double.init) else { return nil }
        let idx = (q["display"].flatMap(Int.init) ?? 1) - 1
        let screens = NSScreen.screens
        let screen = screens.indices.contains(idx) ? screens[idx] : screens[0]
        return CGRect(x: screen.frame.minX + x, y: screen.frame.minY + y, width: w, height: h)
    }
}
