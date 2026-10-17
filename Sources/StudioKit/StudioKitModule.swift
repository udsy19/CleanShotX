import AppKit
import ShotcraftCore

/// Entry point called once by the app at launch; registers this module's services in `Services`.
public enum StudioKitModule {
    @MainActor public static func install() {
        Services.studio = StudioService.shared
    }
}

/// `StudioServicing` (FlowController): owns the active Studio recording and the open editor windows.
@MainActor
final class StudioService: StudioServicing {
    static let shared = StudioService()
    private var session: StudioRecordingSession?
    private var editors: [EditorWindowController] = []

    var isRecording: Bool { session != nil }
    func stopRecording() {
        guard let session else { return }
        if session.isRecording { session.stop() } else { session.cancel() }
    }

    func startStudioRecording(rect: CGRect?) {
        // The shortcut / menu item acts as a toggle while a Studio recording runs.
        if let session {
            if session.isRecording { session.stop() } else { session.cancel() }
            return
        }
        guard Permissions.ensureScreenRecording() else { return }
        if let rect {
            begin(area: rect)
        } else if let capture = Services.capture {
            capture.selectArea(AreaSelectionOptions(purpose: .studio)) { [weak self] selection in
                guard let selection else { return }
                self?.begin(area: selection.rect, screen: selection.screen)
            }
        } else {
            begin(area: NSScreen.active.frame)
        }
    }

    private func begin(area: CGRect, screen: NSScreen? = nil) {
        // ScreenCaptureKit records one display: keep the part of the area on the screen that holds most of it.
        let target = screen ?? NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(area), ib = b.frame.intersection(area)
            return ia.width * ia.height < ib.width * ib.height
        } ?? NSScreen.active
        var rect = area.intersection(target.frame).integral
        if rect.width < 32 || rect.height < 32 { rect = target.frame }
        Defaults[.lastRecordingArea] = CodableRect(rect)
        weak var created: StudioRecordingSession?
        let s = StudioRecordingSession(area: rect, screen: target) { [weak self] url in
            guard let self else { return }
            if self.session === created { self.session = nil }
            if let url { self.openProject(url) }
        }
        created = s
        session = s
        s.begin()
    }

    func openProject(_ url: URL) {
        let key = url.standardizedFileURL
        if let existing = editors.first(where: { $0.model.package.url.standardizedFileURL == key }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let package = StudioPackage(url: key)
        do {
            let (project, recovered) = try package.readProject()
            let model = try EditorModel(package: package, project: project, events: package.readEvents(), recovered: recovered)
            let controller = EditorWindowController(model: model)
            controller.onClose = { [weak self, weak controller] in
                guard let self else { return }
                self.editors.removeAll { $0 === controller }
                // Let the closing window finish ordering out before deciding about the Dock icon.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.updateActivationPolicy() } }
            }
            editors.append(controller)
            updateActivationPolicy()
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            Alerts.error("An error occurred while opening the project", error)
        }
    }

    /// The editor is a regular document window: show the Dock icon (and export progress) while one is open.
    private func updateActivationPolicy() { DockIcon.set("studio", count: editors.count) }
}
