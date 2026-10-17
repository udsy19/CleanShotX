import AppKit
import Combine
import ServiceManagement
import ShotcraftCore
import CaptureKit
import AnnotateKit
import RecordingKit
import StudioKit
import OverlayKit
import TextKit
import PreferencesKit
import UploadKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController!
    private var hotkeyTokens: [UInt32] = []
    private var cancellables = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()
        installModules()
        Services.perform = { ActionRouter.perform($0) }

        MediaPipeline.sweepOrphanedMedia()
        statusMenu = StatusMenuController()
        registerHotkeys()
        Defaults.changes.filter { $0 == Defaults.Keys.shortcuts.name }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotkeys(); self?.statusMenu.rebuild() }
            .store(in: &cancellables)
        Defaults.publisher(.launchAtLogin).dropFirst().sink { LaunchAtLogin.set($0) }.store(in: &cancellables)

        if !Defaults[.onboardingCompleted] {
            Services.preferences.showOnboarding()
        } else if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
        }
    }

    /// Launching the app again while it's running (e.g. from Finder) opens Settings — useful when the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Services.preferences.show(pane: nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openFile(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UploadKitModule.confirmTerminationIfUploading() ? .terminateNow : .terminateCancel
    }

    private func installModules() {
        UploadKitModule.install()
        OverlayKitModule.install()
        CaptureKitModule.install()
        TextKitModule.install()
        AnnotateKitModule.install()
        RecordingKitModule.install()
        StudioKitModule.install()
        PreferencesKitModule.install()
    }

    private func registerHotkeys() {
        hotkeyTokens.forEach { HotkeyCenter.shared.unregister($0) }
        hotkeyTokens = AppAction.allCases.compactMap { action in
            guard let s = action.shortcut else { return nil }
            return HotkeyCenter.shared.register(s) { ActionRouter.perform(action) }
        }
    }

    /// Files opened via Finder / Dock / `open -a`.
    private func openFile(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "shotcraft": Services.annotate.openDocument(url)
        case "shotcraftvideo": Services.studio.openProject(url)
        case "mp4", "mov", "m4v", "gif":
            let kind: MediaKind = url.pathExtension.lowercased() == "gif" ? .gif : .video
            let media = CapturedMedia(url: url, kind: kind, mode: .imported, pixelSize: .zero, scale: 1, isSaved: true)
            Services.recording.openVideoEditor(media)
        default: Services.annotate.open(fileURL: url)
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        URLSchemeHandler.handle(url)
    }
}

enum LaunchAtLogin {
    @MainActor static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
