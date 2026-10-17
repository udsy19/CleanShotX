import AppKit
import SwiftUI
import ShotcraftCore

/// Current sidebar selection; external callers navigate through `show(pane:)`.
@MainActor
final class PreferencesRouter: ObservableObject {
    @Published var selection: PreferencesPane {
        didSet { Defaults[.prefsLastPane] = selection.rawValue }
    }
    init() { selection = PreferencesPane(identifier: Defaults[.prefsLastPane]) ?? .general }
}

/// `PreferencesServicing` implementation: one reusable Settings window plus the onboarding window.
@MainActor
final class PreferencesController: NSObject, PreferencesServicing, NSWindowDelegate {
    static let shared = PreferencesController()

    private let router = PreferencesRouter()
    private var window: NSWindow?
    private var onboarding: OnboardingWindowController?

    func show(pane: String?) {
        if let pane = PreferencesPane(identifier: pane) { router.selection = pane }
        let w = window ?? makeWindow()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    func showOnboarding() {
        let controller = onboarding ?? OnboardingWindowController { [weak self] in self?.onboarding = nil }
        onboarding = controller
        controller.present()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsRootView(router: router))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = hosting
        w.title = "Shotcraft Settings"
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 700, height: 460)
        w.setContentSize(NSSize(width: 780, height: 580))
        w.collectionBehavior.insert(.fullScreenNone)
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("ShotcraftSettingsWindow")  // restores the saved frame, if any
        return w
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Commit any in-progress text edit (e.g. an endpoint field) before the window disappears.
        window?.makeFirstResponder(nil)
    }
}

/// Accessory apps have no Edit menu, so standard editing shortcuts are routed here (⌘X/C/V/A/Z, ⇧⌘Z, ⌘W).
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command || mods == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let selector: Selector?
        switch (key, mods.contains(.shift)) {
        case ("x", false): selector = #selector(NSText.cut(_:))
        case ("c", false): selector = #selector(NSText.copy(_:))
        case ("v", false): selector = #selector(NSText.paste(_:))
        case ("a", false): selector = #selector(NSResponder.selectAll(_:))
        case ("z", false): selector = Selector(("undo:"))
        case ("z", true): selector = Selector(("redo:"))
        case ("w", false): performClose(nil); return true
        default: selector = nil
        }
        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: self)
    }
}

// MARK: - Root view

struct SettingsRootView: View {
    @ObservedObject var router: PreferencesRouter

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<PreferencesPane?>(get: { router.selection },
                                                      set: { if let p = $0 { router.selection = p } })) {
                ForEach(PreferencesPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: router.selection)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .id(router.selection)
        }
    }

    @ViewBuilder private func detail(for pane: PreferencesPane) -> some View {
        switch pane {
        case .general: GeneralPane()
        case .wallpaper: WallpaperPane()
        case .shortcuts: ShortcutsPane()
        case .quickAccess: QuickAccessPane()
        case .recording: RecordingPane()
        case .screenshots: ScreenshotsPane()
        case .annotate: AnnotatePane()
        case .upload: UploadPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}
