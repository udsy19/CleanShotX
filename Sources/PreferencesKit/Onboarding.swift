import AppKit
import SwiftUI
import ShotcraftCore

// MARK: - Window

/// First-run guide (CleanShot's `Onboarding` window controller with `ONView` slides).
/// Closing the window at any step counts as completing onboarding.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Shotcraft"
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in self?.window.close() })
        window.setContentSize(NSSize(width: 620, height: 520))
        window.center()
    }

    func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        Defaults[.onboardingCompleted] = true
        onClose()
    }
}

// MARK: - Steps

enum OnboardingStep: Int, CaseIterable {
    case welcome, screenRecording, shortcuts, desktopIcons, launchAtLogin, afterCapture, finish
}

enum ShortcutChoice: CaseIterable, Identifiable {
    case systemDefaults, allInOneOnly, keepShotcraft
    var id: Self { self }

    var title: String {
        switch self {
        case .systemDefaults: "Use the same shortcuts as macOS"
        case .allInOneOnly: "Use ⇧⌘5 for All-In-One only"
        case .keepShotcraft: "Keep Shotcraft's shortcuts"
        }
    }

    var detail: String {
        switch self {
        case .systemDefaults: "⇧⌘3 Capture Fullscreen · ⇧⌘4 Capture Area · ⇧⌘5 All-In-One"
        case .allInOneOnly: "Like macOS's screenshot toolbar; ⇧⌘3 and ⇧⌘4 keep working as before."
        case .keepShotcraft: "⌥⇧3 Capture Fullscreen · ⌥⇧4 Capture Area · ⌥⇧5 All-In-One — no conflicts with macOS."
        }
    }

    var symbol: String {
        switch self {
        case .systemDefaults: "command.square.fill"
        case .allInOneOnly: "square.dashed.inset.filled"
        case .keepShotcraft: "option"
        }
    }

    var assignments: [(action: AppAction, shortcut: Shortcut)] {
        switch self {
        case .systemDefaults: ShortcutPlanner.systemDefaultAssignments
        case .allInOneOnly: ShortcutPlanner.allInOneOnlyAssignment
        case .keepShotcraft: []
        }
    }
}

// MARK: - Root

struct OnboardingView: View {
    let close: () -> Void
    @State private var step: OnboardingStep = .welcome
    @State private var shortcutChoice: ShortcutChoice = .keepShotcraft
    @StateObject private var permissions = PermissionsModel()
    @StateObject private var system = SystemHotkeysModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .clipped()

            Divider()
            bottomBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.bar)
        }
        .frame(width: 620, height: 520)
        .background(VisualEffectBackground())
        .onAppear { permissions.startMonitoring(); system.poll(true) }
        .onDisappear { permissions.stopMonitoring(); system.poll(false) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            StepLayout(symbol: "camera.aperture", tint: .accentColor, title: "Welcome to Shotcraft",
                       message: "Let's walk you through a quick configuration. It takes less than a minute, and you can change everything later in Settings.") {
                EmptyView()
            }
        case .screenRecording:
            let granted = permissions.states[.screenRecording] == .granted
            StepLayout(symbol: granted ? "checkmark.shield.fill" : "rectangle.dashed.badge.record",
                       tint: granted ? .green : .orange, title: "Allow Screen Recording",
                       message: "Shotcraft needs Screen Recording permission to take screenshots and record your screen. Nothing leaves your Mac unless you upload it.") {
                VStack(spacing: 10) {
                    if granted {
                        Label("Permission granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                    } else {
                        Button("Grant Access…") { permissions.request(.screenRecording) }
                            .controlSize(.large)
                        HelpText("Enable Shotcraft under Privacy & Security → Screen & System Audio Recording. macOS may ask you to reopen the app.")
                            .multilineTextAlignment(.center)
                        Button("Open System Settings") { Permissions.openSettings(.screenRecording) }
                            .buttonStyle(.link)
                    }
                }
            }
        case .shortcuts:
            StepLayout(symbol: "command", tint: .accentColor, title: "Set as default screenshot tool?",
                       message: "Choose how you'd like to trigger captures. You can change any shortcut later.") {
                VStack(spacing: 8) {
                    ForEach(ShortcutChoice.allCases) { choice in
                        ChoiceCard(choice: choice, selected: shortcutChoice == choice) { shortcutChoice = choice }
                    }
                    if shortcutChoice != .keepShotcraft && system.systemShortcutsEnabled {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Turn off the macOS screenshot shortcuts in Keyboard Shortcuts → Screenshots, or macOS will keep handling them.")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                                Button("Open Keyboard Shortcuts…") { system.openKeyboardSettings() }.buttonStyle(.link)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        case .desktopIcons:
            StepLayout(symbol: "menubar.dock.rectangle", tint: .teal, title: "Hide desktop icons while capturing?",
                       message: "Would you like to have your desktop icons hidden automatically whenever you take a screenshot or record your screen?") {
                DesktopIconsSwitch()
            }
        case .launchAtLogin:
            StepLayout(symbol: "power", tint: .green, title: "Launch at login?",
                       message: "Would you like to have Shotcraft ready every time you log in, so your shortcuts always work?") {
                EmptyView()
            }
        case .afterCapture:
            StepLayout(symbol: "sparkles.rectangle.stack", tint: .purple, title: "After capturing",
                       message: "Decide what should happen after taking a screenshot or recording a video. You can adjust all the settings and set your own later.") {
                OnboardingAfterCapture()
            }
        case .finish:
            StepLayout(symbol: nil, tint: .accentColor, title: "Shotcraft is ready to use!",
                       message: "Find Shotcraft in the menu bar at the top of your screen. Click the icon to capture, record, open history or change settings.") {
                MenuBarIllustration()
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            if step != .welcome && step != .finish {
                Button("Back") { go(-1) }
            }
            Spacer()
            PageDots(count: OnboardingStep.allCases.count, index: step.rawValue)
            Spacer()
            HStack {
                secondaryButton
                primaryButton
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var secondaryButton: some View {
        switch step {
        case .screenRecording where permissions.states[.screenRecording] != .granted:
            Button("Later") { go(1) }
        case .launchAtLogin:
            Button("Not Now") { Defaults[.launchAtLogin] = false; go(1) }
        case .finish:
            Button("Open Settings") { close(); Services.preferences?.show(pane: PreferencesPane.general.rawValue) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get Started") { go(1) }.keyboardShortcut(.defaultAction)
        case .shortcuts:
            Button("Continue") {
                let assignments = shortcutChoice.assignments
                if !assignments.isEmpty {
                    Defaults[.shortcuts] = ShortcutPlanner.applying(assignments, to: Defaults[.shortcuts])
                }
                go(1)
            }
            .keyboardShortcut(.defaultAction)
        case .launchAtLogin:
            Button("Launch at Login") { Defaults[.launchAtLogin] = true; go(1) }.keyboardShortcut(.defaultAction)
        case .finish:
            Button("Done") { close() }.keyboardShortcut(.defaultAction)
        default:
            Button("Continue") { go(1) }.keyboardShortcut(.defaultAction)
        }
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        withAnimation(.snappy(duration: 0.3)) { step = next }
    }
}

// MARK: - Pieces

private struct StepLayout<Accessory: View>: View {
    let symbol: String?
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 16) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 54, weight: .regular))
                    .foregroundStyle(tint.gradient)
                    .frame(height: 70)
            }
            Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            accessory.padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChoiceCard: View {
    let choice: ShortcutChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: choice.symbol).font(.title2).frame(width: 30).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title).font(.headline)
                    Text(choice.detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Quick Access / Copy / Save for both screenshots and recordings, never leaving either list empty.
private struct OnboardingAfterCapture: View {
    @Default(.afterScreenshotActions) private var screenshot
    @Default(.afterRecordingActions) private var recording
    private let choices: [AfterCaptureAction] = [.showQuickAccess, .copyToClipboard, .save]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(choices, id: \.self) { action in
                Toggle(action.displayName, isOn: binding(action)).toggleStyle(.checkbox)
            }
        }
        .font(.title3)
    }

    private func binding(_ action: AfterCaptureAction) -> Binding<Bool> {
        Binding(get: { screenshot.contains(action) }, set: { on in
            guard let s = AfterCaptureRules.toggling(action, on: on, in: screenshot) else {
                NSSound.beep()
                HUD.show(AfterCaptureRules.atLeastOneTitle, symbol: "exclamationmark.triangle.fill")
                return
            }
            screenshot = s
            if let r = AfterCaptureRules.toggling(action, on: on, in: recording) { recording = r }
        })
    }
}

private struct DesktopIconsSwitch: View {
    @Default(.hideDesktopIconsWhileCapturing) private var hide
    var body: some View {
        Toggle("Hide desktop icons while capturing", isOn: $hide)
            .toggleStyle(.switch)
            .controlSize(.large)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}

/// A miniature menu bar pointing at the Shotcraft status item.
private struct MenuBarIllustration: View {
    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "camera.aperture")
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .overlay(alignment: .bottom) {
                    Image(systemName: "arrow.up").font(.title2.bold()).foregroundStyle(.tint).offset(y: 34)
                }
            Image(systemName: "switch.2")
            Text(Date.now.formatted(date: .omitted, time: .shortened)).monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(width: 380, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .padding(.bottom, 40)
        .accessibilityLabel("The Shotcraft icon in the menu bar")
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
