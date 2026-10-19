import AppKit
import SwiftUI
import SuperScreenshotCore

/// Watches whether the macOS screenshot shortcuts are enabled (re-read on activation and while a sheet waits).
@MainActor
final class SystemHotkeysModel: ObservableObject {
    @Published private(set) var enabledIDs: Set<Int> = SystemScreenshotHotkeys.currentEnabledIDs()
    private var timer: Timer?
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
        timer?.invalidate()
    }

    func refresh() {
        let ids = SystemScreenshotHotkeys.currentEnabledIDs()
        if ids != enabledIDs { enabledIDs = ids }
    }

    func poll(_ on: Bool) {
        timer?.invalidate(); timer = nil
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var systemShortcutsEnabled: Bool { !enabledIDs.isEmpty }

    func openKeyboardSettings() { NSWorkspace.shared.open(SystemScreenshotHotkeys.keyboardSettingsURL) }
}

struct ShortcutsPane: View {
    @Default(.shortcuts) private var stored
    @StateObject private var system = SystemHotkeysModel()
    @State private var query = ""
    @State private var showingSystemHelper = false
    /// Shortcuts macOS refused to register for us (held by another app).
    @State private var unavailable = HotkeyCenter.shared.unavailable

    var body: some View {
        let effective = ShortcutPlanner.effective(stored)
        let duplicates = ShortcutPlanner.duplicates(in: effective)
        let shadowed = SystemScreenshotHotkeys.shadowedActions(effective: effective, enabledIDs: system.enabledIDs)
        let visible = ShortcutPlanner.filter(AppAction.allCases, query: query) { effective[$0]?.displayString ?? "" }

        PaneForm(pane: .shortcuts) {
            if !shadowed.isEmpty {
                Section {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           title: "It looks like you haven't disabled Screenshots shortcuts.",
                           message: "macOS still handles \(shadowed.compactMap { effective[$0]?.displayString }.joined(separator: ", ")), so \(shadowed.map(\.title).joined(separator: ", ")) won't trigger. Turn off the Screenshots shortcuts in System Settings → Keyboard → Keyboard Shortcuts.",
                           actions: AnyView(Button("Open Keyboard Shortcuts…") { system.openKeyboardSettings() }))
                }
            } else if !ShortcutPlanner.isApplied(ShortcutPlanner.systemDefaultAssignments, in: stored) && query.isEmpty {
                Section {
                    Banner(symbol: "command.square", tint: .accentColor,
                           title: "Use System Default Shortcuts",
                           message: "Make Super Screenshot your default screenshot tool by moving ⇧⌘3, ⇧⌘4 and ⇧⌘5 from macOS to Capture Fullscreen, Capture Area and All-In-One.",
                           actions: AnyView(Button("Set Up…") { showingSystemHelper = true }))
                }
            }

            if visible.isEmpty {
                Section { Text("No shortcuts match “\(query)”.").foregroundStyle(.secondary) }
            }

            ForEach(ShortcutPlanner.grouped(visible), id: \.group) { group in
                Section {
                    ForEach(group.actions, id: \.self) { action in
                        ShortcutRow(action: action, current: effective[action],
                                    isDuplicate: effective[action].map { duplicates[$0] != nil } ?? false,
                                    isShadowed: shadowed.contains(action),
                                    isUnavailable: effective[action].map { unavailable.contains($0) } ?? false)
                    }
                } header: {
                    Label(group.group.title, systemImage: group.group.symbol)
                }
            }

            Section {
                HStack {
                    Button("Use System Default Shortcuts…") { showingSystemHelper = true }
                    Spacer()
                    Button("Restore Defaults") {
                        if Alerts.confirm("Restore default shortcuts?",
                                          info: "All shortcuts you've changed will be replaced with Super Screenshot's defaults.",
                                          confirmTitle: "Restore Defaults") {
                            Defaults.reset(.shortcuts)
                        }
                    }
                }
            } footer: {
                HelpText("Click a field and press a key combination. Press ⌫ to clear a shortcut or Esc to cancel.")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search shortcuts")
        .sheet(isPresented: $showingSystemHelper) {
            SystemShortcutsHelper(system: system) { showingSystemHelper = false }
        }
        .onAppear { system.refresh(); unavailable = HotkeyCenter.shared.unavailable }
        .onReceive(NotificationCenter.default.publisher(for: HotkeyCenter.unavailableDidChange).receive(on: DispatchQueue.main)) { _ in
            unavailable = HotkeyCenter.shared.unavailable
        }
    }
}

private struct ShortcutRow: View {
    let action: AppAction
    let current: Shortcut?
    let isDuplicate: Bool
    let isShadowed: Bool
    let isUnavailable: Bool

    var body: some View {
        // An HStack rather than LabeledContent: the AppKit recorder has no text baseline to align with.
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let d = action.defaultShortcut, d != current {
                    Text("Default: \(d.displayString)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isDuplicate {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    .help("Shortcut is used for another action")
            } else if isShadowed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Shortcut is reserved for macOS")
            } else if isUnavailable {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Another app is already using this shortcut, so it won't trigger. Choose a different one.")
            }
            ShortcutRecorder(for: action)
                .frame(width: 156, height: 28)
                // Recreate the recorder when the stored value changes elsewhere (restore, system defaults).
                .id(current.map { "\($0.keyCode)-\($0.modifierFlags)" } ?? "none")
                .accessibilityLabel("\(action.title) shortcut")
        }
    }
}

/// "Use System Default Shortcuts": explains disabling the macOS screenshot shortcuts, then assigns ⇧⌘3/4/5.
struct SystemShortcutsHelper: View {
    @ObservedObject var system: SystemHotkeysModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "command.square.fill").font(.system(size: 36)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use System Default Shortcuts").font(.title2.bold())
                    Text("Set Super Screenshot as your default screenshot tool.").foregroundStyle(.secondary)
                }
            }

            step(1, "Turn off the macOS screenshot shortcuts",
                 "In System Settings → Keyboard → Keyboard Shortcuts… → Screenshots, uncheck every shortcut so macOS stops reacting to ⇧⌘3, ⇧⌘4 and ⇧⌘5.") {
                HStack {
                    Button("Open Keyboard Shortcuts…") { system.openKeyboardSettings() }
                    if system.systemShortcutsEnabled {
                        Label("Still enabled", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Label("Disabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }

            step(2, "Assign the shortcuts to Super Screenshot",
                 "⇧⌘3 → Capture Fullscreen, ⇧⌘4 → Capture Area, ⇧⌘5 → All-In-One. Other actions using these keys are cleared.") {
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button("Assign Shortcuts") {
                    Defaults[.shortcuts] = ShortcutPlanner.applying(ShortcutPlanner.systemDefaultAssignments, to: Defaults[.shortcuts])
                    dismiss()
                    HUD.show("Shortcuts assigned", symbol: "command")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { system.refresh(); system.poll(true) }
        .onDisappear { system.poll(false) }
    }

    private func step<A: View>(_ n: Int, _ title: String, _ detail: String, @ViewBuilder accessory: () -> A) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                HelpText(detail)
                accessory()
            }
        }
    }
}
