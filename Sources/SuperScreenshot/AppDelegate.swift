import AppKit
import Combine
import ServiceManagement
import SuperScreenshotCore
import CaptureKit
import AnnotateKit
import RecordingKit
import StudioKit
import OverlayKit
import TextKit
import PreferencesKit
import UploadKit
import UpdateKit

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
        recoverInterruptedWork()
        Defaults.changes.filter { $0 == Defaults.Keys.shortcuts.name }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotkeys(); self?.statusMenu.rebuild() }
            .store(in: &cancellables)
        Defaults.publisher(.launchAtLogin).dropFirst().sink { LaunchAtLogin.set($0) }.store(in: &cancellables)
        // Preferences carried over from the previous app name: register this app as the login item.
        if LegacyMigration.didMigratePreferences && Defaults[.launchAtLogin] { LaunchAtLogin.set(true) }

        if !Defaults[.onboardingCompleted] {
            Services.preferences.showOnboarding()
        } else if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
        }
    }

    /// Work the previous run left behind (crash, force quit, power loss): interrupted recordings become ordinary
    /// recordings; unsaved annotation edits are offered for reopening.
    private func recoverInterruptedWork() {
        Task { @MainActor in
            await RecordingRecovery.recoverAll()
            AnnotateKitModule.recoverUnsavedDocuments()
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

    /// Quit order: anything that can veto the quit asks first (unsaved annotations, running uploads); then a running
    /// recording is stopped and the quit waits until its file is finalized, so ⌘Q never truncates a recording.
    /// The update swap helper only starts in `applicationWillTerminate`, i.e. after all of this.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AnnotateKitModule.confirmTerminationIfUnsaved() else { return .terminateCancel }
        guard UploadKitModule.confirmTerminationIfUploading() else { return .terminateCancel }
        guard ActionRouter.isRecordingBusy else { return .terminateNow }
        Services.recording?.stopRecording()
        Services.studio?.stopRecording()
        let deadline = Date().addingTimeInterval(30)
        let timer = Timer(timeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !ActionRouter.isRecordingBusy || Date() > deadline else { return }
                timer.invalidate()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        UpdateKitModule.applicationWillTerminate()
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
        UpdateKitModule.install()
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
        case SuperScreenshotDocument.fileExtension, SuperScreenshotDocument.legacyFileExtension:
            Services.annotate.openDocument(url)
        case StudioPackage.fileExtension, StudioPackage.legacyFileExtension: Services.studio.openProject(url)
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
