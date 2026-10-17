import AppKit
import SwiftUI
import ShotcraftCore

// MARK: - Window

/// First-run guide (CleanShot's `Onboarding` window controller with `ONView` slides).
/// Closing the window at any step counts as completing onboarding.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 580, height: 560)

    private let window: NSWindow
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Shotcraft"
        window.delegate = self
        let hosting = NSHostingController(rootView: OnboardingView { [weak self] in self?.window.close() })
        hosting.sizingOptions = []   // fixed-size window; slides never resize it
        window.contentViewController = hosting
        window.setContentSize(Self.size)
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
    case welcome, privacy, screenRecording, shortcuts, desktopIcons, launchAtLogin, workflow, finish
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
        case .keepShotcraft: "⌥⇧3 Fullscreen · ⌥⇧4 Area · ⌥⇧5 All-In-One — no conflicts with macOS."
        }
    }

    var symbol: String {
        switch self {
        case .systemDefaults: "command"
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
    @State private var step: OnboardingStep

    /// `start` lets previews and snapshot checks open a specific slide.
    init(start: OnboardingStep = .welcome, close: @escaping () -> Void) {
        self.close = close
        _step = State(initialValue: start)
    }
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
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .clipped()

            Divider()
            bottomBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .background(VisualEffectBackground())
        // The title bar is transparent; without this its safe-area inset pushes the bottom bar out of the window.
        .ignoresSafeArea()
        .onAppear { permissions.startMonitoring() }
        .onDisappear { permissions.stopMonitoring(); system.poll(false) }
        // Only the shortcuts slide shows the macOS shortcut state; poll it while that slide is visible.
        .onChange(of: step) { _, new in system.poll(new == .shortcuts) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            StepLayout(title: "Welcome to Shotcraft",
                       message: "Let's walk you through a quick configuration. It takes less than a minute, and you can change everything later in Settings.") {
                AppIconImage(size: 96)
            } accessory: {
                FeatureSummary()
            }
        case .privacy:
            StepLayout(title: "Private by design",
                       message: "Shotcraft is a local app. Screenshots, recordings, annotations and text recognition all happen on your Mac — nothing leaves it unless you set up an upload destination yourself.") {
                IconTile(symbol: "lock.shield.fill", tint: PreferencesPane.quickAccess.tint, size: 72)
            } accessory: {
                PrivacyPoints()
            }
        case .screenRecording:
            let granted = permissions.states[.screenRecording] == .granted
            StepLayout(title: "Allow Screen Recording",
                       message: "Shotcraft needs Screen Recording permission to take screenshots and record your screen. Nothing leaves your Mac unless you upload it.") {
                IconTile(symbol: granted ? "checkmark" : "rectangle.dashed.badge.record",
                         tint: granted ? PreferencesPane.quickAccess.tint : PreferencesPane.recording.tint, size: 72)
            } accessory: {
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
            StepLayout(title: "Set as default screenshot tool?",
                       message: "Choose how you'd like to trigger captures. You can change any shortcut later.") {
                KeycapsIllustration(keys: shortcutChoice == .keepShotcraft ? ["⌥", "⇧", "4"] : ["⇧", "⌘", "4"])
            } accessory: {
                VStack(spacing: 8) {
                    ForEach(ShortcutChoice.allCases) { choice in
                        ChoiceCard(choice: choice, selected: shortcutChoice == choice) { shortcutChoice = choice }
                    }
                    if shortcutChoice != .keepShotcraft && system.systemShortcutsEnabled {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("It looks like you haven't disabled Screenshots shortcuts in macOS.")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                                Button("Open Keyboard Shortcuts…") { system.openKeyboardSettings() }.buttonStyle(.link)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        case .desktopIcons:
            StepLayout(title: "Hide desktop icons while capturing?",
                       message: "Would you like to have your desktop icons hidden automatically whenever you take a screenshot or record your screen?") {
                DesktopIllustration()
            } accessory: {
                DesktopIconsSwitch()
            }
        case .launchAtLogin:
            StepLayout(title: "Launch at login?",
                       message: "Would you like to have Shotcraft ready every time you log in, so your shortcuts always work?") {
                MenuBarIllustration(highlight: false)
            } accessory: {
                EmptyView()
            }
        case .workflow:
            StepLayout(title: "Tweak your workflow",
                       message: "Decide what should happen after taking a screenshot or recording a video. You can adjust all the settings and set your own later.") {
                IconTile(symbol: "slider.horizontal.3", tint: PreferencesPane.advanced.tint, size: 64)
            } accessory: {
                OnboardingAfterCapture()
            }
        case .finish:
            StepLayout(title: "Shotcraft is ready to use!",
                       message: "You can access the app through the menu bar icon or by using the defined keyboard shortcuts.") {
                AppIconImage(size: 88)
            } accessory: {
                VStack(spacing: 4) {
                    MenuBarIllustration(highlight: true)
                    ShortcutTips()
                }
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        ZStack {
            PageDots(count: OnboardingStep.allCases.count, index: step.rawValue)
            HStack {
                if step != .welcome && step != .finish {
                    Button("Back") { go(-1) }
                }
                Spacer()
                secondaryButton
                primaryButton.buttonStyle(.borderedProminent)
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

// MARK: - Slide layout (ONBasicView: image, 22 pt title, 13 pt body)

private struct StepLayout<Illustration: View, Accessory: View>: View {
    let title: String
    let message: String
    @ViewBuilder var illustration: Illustration
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 12) {
            illustration
                .frame(height: 100)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            accessory.padding(.top, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AppIconImage: View {
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Welcome slide: what Shotcraft does, as a 2 × 3 grid of feature tiles.
/// The "Private by design" slide: what stays on the Mac, and why macOS asked before the first launch.
private struct PrivacyPoints: View {
    private let points: [(symbol: String, text: String)] = [
        ("internaldrive.fill", "Captures are saved only on this Mac."),
        ("person.crop.circle.badge.xmark", "No account, no analytics, no tracking."),
        ("arrow.up.circle", "Uploads happen only to a destination you configure."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(points, id: \.text) { p in
                Label { Text(p.text).font(.callout) } icon: {
                    Image(systemName: p.symbol).foregroundStyle(.secondary).frame(width: 20)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Why did macOS ask before opening Shotcraft?").font(.callout.weight(.semibold))
                    Text("Shotcraft is an independent, open-source app that isn't notarized by Apple, so macOS asked you to confirm it under Privacy & Security → Open Anyway. That's expected and only needed once.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        .frame(maxWidth: 420)
    }
}

private struct FeatureSummary: View {
    private struct Feature: Identifiable {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        var id: String { title }
    }

    private let features = [
        Feature(symbol: "camera.fill", tint: PreferencesPane.screenshots.tint, title: "Screenshots",
                detail: "Area, window, scrolling"),
        Feature(symbol: "video.fill", tint: PreferencesPane.recording.tint, title: "Screen Recording",
                detail: "Video and GIF"),
        Feature(symbol: "pencil", tint: PreferencesPane.annotate.tint, title: "Annotate",
                detail: "Arrows, text, blur"),
        Feature(symbol: "text.viewfinder", tint: PreferencesPane.advanced.tint, title: "Capture Text",
                detail: "Copy text from screen"),
        Feature(symbol: "rectangle.and.hand.point.up.left.fill", tint: PreferencesPane.quickAccess.tint,
                title: "Quick Access", detail: "Drag, copy, pin, save"),
        Feature(symbol: "cloud.fill", tint: PreferencesPane.upload.tint, title: "Upload",
                detail: "Share links to captures"),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
            ForEach(features) { f in
                HStack(spacing: 10) {
                    IconTile(symbol: f.symbol, tint: f.tint, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.title).font(.system(size: 13, weight: .semibold))
                        Text(f.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: 470)
    }
}

private struct ChoiceCard: View {
    let choice: ShortcutChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: choice.symbol).font(.title3).frame(width: 26).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title).font(.system(size: 13, weight: .semibold))
                    Text(choice.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
    /// Bumped when a change is refused, so the checkbox snaps back.
    @State private var revision = 0
    private let choices: [AfterCaptureAction] = [.showQuickAccess, .copyToClipboard, .save]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(choices, id: \.self) { action in
                Toggle(action.displayName, isOn: binding(action)).toggleStyle(.checkbox)
            }
        }
        .id(revision)
    }

    private func binding(_ action: AfterCaptureAction) -> Binding<Bool> {
        Binding(get: { screenshot.contains(action) }, set: { on in
            guard let s = AfterCaptureRules.toggling(action, on: on, in: screenshot) else {
                revision += 1
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
        SettingToggle("Hide desktop icons while capturing", isOn: $hide)
            .toggleStyle(.switch)
    }
}

/// The shortcuts in effect for the most common captures (reflects the choice made on the shortcuts slide).
private struct ShortcutTips: View {
    @Default(.shortcuts) private var stored
    private let actions: [AppAction] = [.allInOne, .captureArea, .captureFullscreen, .recordScreen, .captureText]

    var body: some View {
        let effective = ShortcutPlanner.effective(stored)
        VStack(spacing: 0) {
            ForEach(actions.filter { effective[$0] != nil }, id: \.self) { action in
                HStack {
                    Text(action.title).font(.system(size: 13))
                    Spacer()
                    Text(effective[action]?.displayString ?? "")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                }
                .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .frame(maxWidth: 380)
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

// MARK: - Illustrations

/// Keyboard keys for the shortcuts slide.
private struct KeycapsIllustration: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                    .shadow(color: .black.opacity(0.15), radius: 0, y: 2)
            }
        }
        .animation(.snappy, value: keys)
        .accessibilityLabel("Keyboard shortcut \(keys.joined())")
    }
}

/// A miniature desktop whose icons fade out while the switch is on.
private struct DesktopIllustration: View {
    @Default(.hideDesktopIconsWhileCapturing) private var hide

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.98), Color(red: 0.72, green: 0.42, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 6) {
                ForEach(["folder.fill", "doc.fill", "photo.fill"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.white)
                }
            }
            .padding(10)
            .opacity(hide ? 0 : 1)
            .scaleEffect(hide ? 0.8 : 1)
        }
        .frame(width: 160, height: 96)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .animation(.snappy, value: hide)
        .accessibilityHidden(true)
    }
}

/// A miniature menu bar with the Shotcraft status item; `highlight` points an arrow at it.
private struct MenuBarIllustration: View {
    let highlight: Bool

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
                    if highlight {
                        Image(systemName: "arrow.up").font(.title2.bold()).foregroundStyle(.tint).offset(y: 34)
                    }
                }
            Image(systemName: "switch.2")
            Text(Date.now.formatted(date: .omitted, time: .shortened)).monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(width: 380, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .padding(.bottom, highlight ? 40 : 0)
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
