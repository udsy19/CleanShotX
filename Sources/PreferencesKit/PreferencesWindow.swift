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

    /// Moves the selection up or down the sidebar (About is the last row).
    func step(_ delta: Int) {
        let all = PreferencesPane.allCases
        guard let i = all.firstIndex(of: selection) else { return }
        selection = all[min(max(0, i + delta), all.count - 1)]
    }
}

/// `PreferencesServicing` implementation: one reusable Settings window plus the onboarding window.
@MainActor
final class PreferencesController: NSObject, PreferencesServicing, NSWindowDelegate {
    static let shared = PreferencesController()

    /// CleanShot 5.0's settings window is 810×660 pt and only grows vertically.
    static let contentWidth: CGFloat = 810
    static let defaultHeight: CGFloat = 660
    static let minHeight: CGFloat = 480

    private let router = PreferencesRouter()
    private var window: NSWindow?
    private var onboarding: OnboardingWindowController?

    func show(pane: String?) {
        if let pane = PreferencesPane(identifier: pane) { router.selection = pane }
        let w = window ?? makeWindow()
        window = w
        NSApp.activate()
        if w.isMiniaturized { w.deminiaturize(nil) }
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
        // The window owns its size; SwiftUI only contributes a minimum, so switching panes never resizes or
        // collapses the window to a pane's ideal size.
        hosting.sizingOptions = [.minSize]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.defaultHeight),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = hosting
        w.title = "Shotcraft Settings"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: Self.contentWidth, height: Self.minHeight)
        w.contentMaxSize = NSSize(width: Self.contentWidth, height: .greatestFiniteMagnitude)
        w.setContentSize(NSSize(width: Self.contentWidth, height: Self.defaultHeight))
        w.collectionBehavior.insert(.fullScreenNone)
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("ShotcraftSettingsWindow")  // restores the saved frame, if any
        // A frame saved by an older build may have another width or sit off-screen; normalise it.
        var content = w.contentRect(forFrameRect: w.frame)
        content.size.width = Self.contentWidth
        content.size.height = max(content.height, Self.minHeight)
        var frame = w.frameRect(forContentRect: content)
        if let visible = (w.screen ?? NSScreen.main)?.visibleFrame {
            if !visible.intersects(frame) { frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2) }
            frame.size.height = min(frame.height, visible.height)
            frame.origin.y = max(frame.origin.y, visible.minY)
        }
        w.setFrame(frame, display: false)
        return w
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Commit any in-progress text edit (e.g. an endpoint field) before the window disappears.
        window?.makeFirstResponder(nil)
    }
}

// MARK: - Root view

struct SettingsRootView: View {
    @ObservedObject var router: PreferencesRouter

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(router: router)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
        } detail: {
            detail(for: router.selection)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .id(router.selection)
        }
        // In-app links such as "[wallpaper settings](settings://wallpaper)" switch panes.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "settings" else { return .systemAction }
            if let pane = PreferencesPane(identifier: url.host) { router.selection = pane }
            return .handled
        })
    }

    @ViewBuilder private func detail(for pane: PreferencesPane) -> some View {
        switch pane {
        case .general: GeneralPane()
        case .shortcuts: ShortcutsPane()
        case .quickAccess: QuickAccessPane()
        case .wallpaper: WallpaperPane()
        case .screenshots: ScreenshotsPane()
        case .recording: RecordingPane()
        case .annotate: AnnotatePane()
        case .upload: UploadPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Sidebar (PRMenuControl)

/// CleanShot 5.0 sidebar: an identity header, coloured icon tiles at a 40 pt pitch with a soft grey selection
/// pill, and About pinned to the bottom. ↑/↓ move the selection while the sidebar has keyboard focus.
private struct SettingsSidebar: View {
    @ObservedObject var router: PreferencesRouter
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader { router.selection = .upload }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(PreferencesPane.sidebarPanes) { row($0) }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
            row(.about)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: router.step(-1)
            case .down: router.step(1)
            default: break
            }
        }
    }

    private func row(_ pane: PreferencesPane) -> some View {
        SidebarRow(pane: pane, selected: router.selection == pane, focused: focused) {
            router.selection = pane
            focused = true
        }
    }
}

private struct SidebarRow: View {
    let pane: PreferencesPane
    let selected: Bool
    let focused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: pane.symbol, tint: pane.tint)
                Text(pane.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(focused ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Stand-in for CleanShot's Cloud account header: app identity plus the upload destination, which opens the
/// Upload pane.
private struct SidebarHeader: View {
    let openUpload: () -> Void
    @Default(.uploadDestination) private var destination

    var body: some View {
        Button(action: openUpload) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().interpolation(.high)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shotcraft").font(.system(size: 13, weight: .semibold))
                    Text(destination == .none ? "Set up uploads" : destination.displayName)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Upload settings")
    }
}
