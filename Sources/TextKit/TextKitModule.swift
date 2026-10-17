import AppKit
import ShotcraftCore

/// Entry point called once by the app at launch; registers this module's services in `Services`.
public enum TextKitModule {
    @MainActor public static func install() {
        Services.text = TextService.shared
        TextRecognizer.warmUp()
    }
}

/// Capture Text (OCR) and Scrolling Capture.
@MainActor final class TextService: TextServicing {
    static let shared = TextService()

    private var isBusy = false
    private var scrollingSession: ScrollingCaptureSession?

    // MARK: Capture Text

    func captureText(keepLineBreaks: Bool?) {
        guard !isBusy, scrollingSession == nil, Permissions.ensureScreenRecording() else { return }
        let keep = keepLineBreaks ?? Defaults[.ocrKeepLineBreaks]
        isBusy = true
        Services.capture.selectArea(AreaSelectionOptions(purpose: .text, allowsWindowSelection: true)) { [weak self] selection in
            guard let self else { return }
            guard let selection, selection.rect.width >= 4, selection.rect.height >= 4 else { self.isBusy = false; return }
            Task { @MainActor in
                do {
                    let image = try await Self.grab(selection)
                    self.recognizeText(in: image, keepLineBreaks: keep) { text in
                        self.isBusy = false
                        self.deliver(text)
                    }
                } catch {
                    self.isBusy = false
                    Alerts.error("Screen content error", error)
                }
            }
        }
    }

    /// A clicked window is captured on its own (even if covered); a dragged area as seen on screen.
    private static func grab(_ selection: AreaSelection) async throws -> CGImage {
        if let id = selection.windowID {
            return try await ScreenCapturer.capture(windowID: id, shadow: false).0
        }
        return try await ScreenCapturer.capture(globalRect: selection.rect, showsCursor: false).0
    }

    func recognizeText(in image: CGImage, keepLineBreaks: Bool, completion: @escaping (String) -> Void) {
        let configuration = TextRecognizer.Configuration.current()
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            do {
                text = try TextRecognizer.recognizeText(in: image, keepLineBreaks: keepLineBreaks, configuration: configuration)
            } catch {
                Log.capture.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                text = ""
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    private func deliver(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            HUD.show("No text detected", symbol: "text.magnifyingglass")
            return
        }
        Clipboard.copy(text: text)
        Sound.play(.textCopied)
        HUD.show("Text has been copied", symbol: "doc.on.clipboard.fill")
        if Defaults[.ocrOpenLinks], let url = TextAssembler.singleURL(in: text) {
            // Let the HUD appear before the modal alert.
            DispatchQueue.main.async { Self.offerToOpen(url) }
        }
    }

    private static func offerToOpen(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Do you want to open this link?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open Link in Browser")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Never open links")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(url)
        case .alertThirdButtonReturn: Defaults[.ocrOpenLinks] = false
        default: break
        }
    }

    // MARK: Scrolling Capture

    func supportedLanguages() -> [(code: String, name: String)] { TextRecognizer.supportedLanguages() }

    func startScrollingCapture(_ options: CaptureOptions) {
        guard scrollingSession == nil, !isBusy, Permissions.ensureScreenRecording() else { return }
        if let rect = options.rect {
            guard let screen = Self.screen(for: rect) else { return }
            begin(area: rect, screen: screen, options: options)
            return
        }
        isBusy = true   // selection overlay is up
        Services.capture.selectArea(AreaSelectionOptions(purpose: .scrolling, allowsWindowSelection: true)) { [weak self] selection in
            guard let self else { return }
            self.isBusy = false
            guard let selection else { return }
            self.begin(area: selection.rect, screen: selection.screen, options: options)
        }
    }

    private func begin(area: CGRect, screen: NSScreen, options: CaptureOptions) {
        let clipped = area.intersection(screen.frame)
        guard clipped.width >= 40, clipped.height >= 40 else {
            HUD.show("Select a larger area to capture", symbol: "exclamationmark.triangle.fill")
            return
        }
        let session = ScrollingCaptureSession(area: clipped, screen: screen, options: options) { [weak self] in
            self?.scrollingSession = nil
        }
        scrollingSession = session
        session.begin()
    }

    /// The screen showing most of `rect`.
    private static func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }.flatMap { $0.frame.intersects(rect) ? $0 : nil }
    }
}
