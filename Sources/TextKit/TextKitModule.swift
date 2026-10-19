import AppKit
import SuperScreenshotCore

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
            let screen = selection.screen
            Task { @MainActor in
                do {
                    let image = try await withTimeout(seconds: ScreenCapturer.timeout) { try await Self.grab(selection) }
                    self.recognize(image, keepLineBreaks: keep) { text, barcodes, error in
                        self.isBusy = false
                        if let error {
                            Toast.show("Couldn't recognize text", symbol: "exclamationmark.triangle.fill", on: screen)
                            Log.capture.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                        self.deliver(text, barcodes: barcodes, on: screen)
                    }
                } catch {
                    self.isBusy = false
                    ScreenCapturer.report(error, "Couldn't capture the screen.")
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
        recognize(image, keepLineBreaks: keepLineBreaks) { text, _, error in
            // Callers only get text; a failure (unsupported language set, damaged image) is explained here.
            if let error { Alerts.error("Couldn't recognize text.", error) }
            completion(text)
        }
    }

    /// Runs Vision off the main thread; `completion` gets the composed text, the barcode payloads and the error
    /// if recognition failed (text is then empty), on main.
    private func recognize(_ image: CGImage, keepLineBreaks: Bool, completion: @escaping (String, [String], Error?) -> Void) {
        let configuration = TextRecognizer.Configuration.current()
        DispatchQueue.global(qos: .userInitiated).async {
            var text = "", barcodes: [String] = [], failure: Error?
            do {
                let result = try TextRecognizer.recognize(in: image, configuration: configuration)
                barcodes = result.barcodes
                text = TextRecognizer.compose(text: TextAssembler.assemble(result.lines, keepLineBreaks: keepLineBreaks),
                                              barcodes: barcodes)
            } catch {
                Log.capture.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                failure = error
            }
            DispatchQueue.main.async { completion(text, barcodes, failure) }
        }
    }

    private func deliver(_ raw: String, barcodes: [String], on screen: NSScreen) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            Toast.show("No text detected", symbol: "text.magnifyingglass", on: screen)
            return
        }
        Clipboard.copy(text: text)
        Sound.play(.textCopied)
        Toast.show("Text has been copied", symbol: "doc.on.doc", on: screen)
        // A QR code with a link, or a capture that is exactly one link.
        if Defaults[.ocrOpenLinks], let url = barcodes.lazy.compactMap(TextAssembler.singleURL).first ?? TextAssembler.singleURL(in: text) {
            // Let the toast appear before the modal alert.
            DispatchQueue.main.async { Self.offerToOpen(url) }
        }
    }

    private static func offerToOpen(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Do you want to open this link?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open Link in Browser")
        alert.addButton(withTitle: "Don't Open")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't detect links"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { Defaults[.ocrOpenLinks] = false }
        if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
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
            Toast.show("Select a larger area to capture", symbol: "exclamationmark.triangle.fill", on: screen)
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
