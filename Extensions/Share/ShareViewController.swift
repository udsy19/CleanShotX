import AppKit
import UniformTypeIdentifiers

/// Share-menu extension ("Annotate with Shotcraft" / "Pin to the Screen"). Receives one image, stores it where the
/// main app can read it, and hands it over via the URL scheme. Compiled twice: with `-D PIN` for the pin variant.
final class ShareViewController: NSViewController {
    #if PIN
    private let command = "pin"
    #else
    private let command = "open-annotate"
    #endif

    override func loadView() {
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        view = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 60))
        spinner.frame.origin = NSPoint(x: 24, y: 14)
        view.addSubview(spinner)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let item = (extensionContext?.inputItems as? [NSExtensionItem])?.first,
              let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            finish(); return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] obj, _ in
                let url = (obj as? URL) ?? (obj as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                DispatchQueue.main.async { self?.handOff(url) }
            }
        } else {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                var url: URL?
                if let data, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Shared \(UUID().uuidString.prefix(8)).png")
                    if (try? png.write(to: dest)) != nil { url = dest }
                }
                DispatchQueue.main.async { self?.handOff(url) }
            }
        }
    }

    private func handOff(_ file: URL?) {
        if let file, var c = URLComponents(string: "shotcraft://\(command)") {
            c.queryItems = [URLQueryItem(name: "filepath", value: file.path)]
            if let url = c.url { NSWorkspace.shared.open(url) }
        }
        finish()
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}
