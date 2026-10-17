import AppKit
import AVFoundation
import Combine
import SwiftUI
import ShotcraftCore

// MARK: - Pane scaffold

/// A grouped form with the pane's title in the toolbar, used by every pane. Grouped forms already draw toggles as
/// the mini trailing switches of CleanShot's 5.0 settings.
struct PaneForm<Content: View>: View {
    let pane: PreferencesPane
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
    }
}

/// Secondary explanatory text under a control or below a section.
struct HelpText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        // Inline Markdown, so help lines can carry links such as [wallpaper settings](settings://wallpaper).
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Toggle with an optional description line underneath the title.
struct SettingToggle: View {
    let title: String
    var help: String?
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>, help: String? = nil) {
        self.title = title; self._isOn = isOn; self.help = help
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            if let help { Text(help) }
        }
        // Grouped forms expose the label and the switch as separate elements; name the switch for VoiceOver.
        .accessibilityLabel(title)
        .accessibilityHint(help ?? "")
    }
}

/// A grey "Options…" button that opens a popover with extra settings for its row.
struct OptionsButton<Content: View>: View {
    var title = "Options…"
    @ViewBuilder var content: Content
    @State private var showing = false

    var body: some View {
        Button(title) { showing.toggle() }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Form { content }.formStyle(.grouped).frame(width: 300).fixedSize(horizontal: false, vertical: true)
            }
    }
}

/// Section header with an optional description line, as in "After Capture".
struct SectionHeader: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail).font(.callout).fontWeight(.regular).foregroundStyle(.secondary).textCase(nil)
            }
        }
    }
}

/// Inline red note under a field whose value is invalid; renders nothing when `problem` is nil.
struct ValidationNote: View {
    let problem: String?
    var body: some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(.red)
        }
    }
}

// MARK: - Sidebar tiles

extension PreferencesPane {
    /// Fill of the System-Settings-style icon tile (CleanShot 5.0 sidebar colours).
    var tint: Color {
        switch self {
        case .general, .shortcuts, .about: Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
        case .quickAccess: Color(red: 0x1B / 255, green: 0xA4 / 255, blue: 0x5B / 255)
        case .wallpaper: Color(red: 0x5A / 255, green: 0xC8 / 255, blue: 0xE0 / 255)
        case .screenshots: Color(red: 0x1A / 255, green: 0x8C / 255, blue: 0xFF / 255)
        case .recording: Color(red: 0xE8 / 255, green: 0x34 / 255, blue: 0x4E / 255)
        case .annotate: Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x1F / 255)
        case .upload: Color(red: 0x2F / 255, green: 0x7B / 255, blue: 0xF6 / 255)
        case .advanced: Color(red: 0x7D / 255, green: 0x4C / 255, blue: 0xDB / 255)
        }
    }
}

/// Colour-filled rounded square with a white SF Symbol (sidebar rows, onboarding feature list).
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(tint.gradient)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

// MARK: - Colors

extension RGBAColor {
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent),
                  a: Double(ns.alphaComponent))
    }
}

extension Binding where Value == Double {
    /// Snaps written values to multiples of `step` without the tick marks a stepped `Slider` draws.
    func snapped(to step: Double) -> Binding<Double> {
        Binding(get: { wrappedValue }, set: { wrappedValue = ($0 / step).rounded() * step })
    }
}

extension Binding where Value == RGBAColor {
    var color: Binding<Color> {
        Binding<Color>(get: { wrappedValue.swiftUIColor }, set: { wrappedValue = RGBAColor($0) })
    }
}

// MARK: - Panels

@MainActor
enum Panels {
    static func chooseFolder(title: String, current: String?) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = "Choose"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        if let current, !current.isEmpty {
            p.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath, isDirectory: true)
        }
        NSApp.activate()
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseImage(title: String) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = "Choose"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image]
        NSApp.activate()
        return p.runModal() == .OK ? p.url : nil
    }

    static func reveal(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSSound.beep()
        }
    }
}

/// "Export location"-style row: current folder with icon, Choose… and Show in Finder.
struct FolderRow: View {
    let title: String
    @Binding var path: String
    var placeholder = "Not set"

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if !path.isEmpty {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: (path as NSString).expandingTildeInPath))
                        .resizable().frame(width: 16, height: 16)
                }
                Text(path.isEmpty ? placeholder : displayName)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .help(path)
                Button("Choose…") {
                    if let url = Panels.chooseFolder(title: title, current: path) { path = url.path }
                }
                Button {
                    Panels.reveal(path: path)
                } label: { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .disabled(path.isEmpty)
            }
        }
    }

    private var displayName: String {
        FileManager.default.displayName(atPath: (path as NSString).expandingTildeInPath)
    }
}

// MARK: - Warning banner

struct Banner: View {
    let symbol: String
    let tint: Color
    let title: String
    var message: String?
    var actions: AnyView?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let message { HelpText(message) }
                if let actions { actions.padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Permissions

enum PermissionKind: CaseIterable, Identifiable {
    case screenRecording, accessibility, microphone, camera
    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .camera: "Camera"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: "Required for screenshots and recordings."
        case .accessibility: "Needed to show keystrokes in recordings."
        case .microphone: "Needed to record your voice."
        case .camera: "Needed to show your camera in recordings."
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .microphone: "mic"
        case .camera: "video"
        }
    }

    var pane: Permissions.Pane {
        switch self {
        case .screenRecording: .screenRecording
        case .accessibility: .accessibility
        case .microphone: .microphone
        case .camera: .camera
        }
    }
}

enum PermissionState { case granted, notDetermined, denied }

/// Permission state, re-read whenever the app becomes active (the user returns from System Settings) and polled
/// while a view showing it is visible (System Settings changes don't notify us).
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    private var timer: Timer?
    private var observers = 0
    private var activation: NSObjectProtocol?

    init() {
        refresh()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
        timer?.invalidate()
    }

    func refresh() {
        var s: [PermissionKind: PermissionState] = [:]
        s[.screenRecording] = Permissions.hasScreenRecording ? .granted : .denied
        s[.accessibility] = Permissions.hasAccessibility ? .granted : .denied
        s[.microphone] = Self.map(Permissions.status(for: .audio))
        s[.camera] = Self.map(Permissions.status(for: .video))
        if s != states { states = s }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func startMonitoring() {
        observers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopMonitoring() {
        observers = max(0, observers - 1)
        if observers == 0 { timer?.invalidate(); timer = nil }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .screenRecording:
            if !Permissions.requestScreenRecording() { Permissions.openSettings(.screenRecording) }
        case .accessibility:
            // The prompt only appears once; afterwards the user has to flip the switch in System Settings.
            Permissions.requestAccessibility()
            Permissions.openSettings(.accessibility)
        case .microphone, .camera:
            let media: AVMediaType = kind == .microphone ? .audio : .video
            if states[kind] == .notDetermined {
                Permissions.request(media) { [weak self] _ in self?.refresh() }
            } else {
                Permissions.openSettings(kind.pane)
            }
        }
        refresh()
    }
}

struct PermissionRow: View {
    let kind: PermissionKind
    @ObservedObject var model: PermissionsModel

    var body: some View {
        let state = model.states[kind] ?? .denied
        LabeledContent {
            HStack(spacing: 8) {
                statusLabel(state)
                if state != .granted {
                    Button(state == .notDetermined ? "Request…" : "Open System Settings") { model.request(kind) }
                }
            }
        } label: {
            Label {
                Text(kind.title)
                Text(kind.purpose)
            } icon: { Image(systemName: kind.symbol) }
        }
    }

    @ViewBuilder private func statusLabel(_ state: PermissionState) -> some View {
        switch state {
        case .granted: Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notDetermined: Label("Not requested", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .denied: Label("Not granted", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Section listing the given permissions with live status.
struct PermissionsSection: View {
    var kinds: [PermissionKind] = PermissionKind.allCases
    var footer: String? = "Shotcraft only asks for the permissions a feature needs. Changes made in System Settings appear here automatically."
    @StateObject private var model = PermissionsModel()

    var body: some View {
        Section {
            ForEach(kinds) { PermissionRow(kind: $0, model: model) }
        } header: { Text("Permissions") } footer: {
            if let footer { HelpText(footer) }
        }
        .onAppear { model.startMonitoring() }
        .onDisappear { model.stopMonitoring() }
    }
}

// MARK: - Capture devices

struct CaptureDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class CaptureDevicesModel: ObservableObject {
    @Published private(set) var microphones: [CaptureDeviceInfo] = []
    @Published private(set) var cameras: [CaptureDeviceInfo] = []
    private var tokens: [NSObjectProtocol] = []

    init() {
        reload()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    func reload() {
        let audio = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let video = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                                     mediaType: .video, position: .unspecified)
        microphones = Self.unique(audio.devices)
        cameras = Self.unique(video.devices)
    }

    private static func unique(_ devices: [AVCaptureDevice]) -> [CaptureDeviceInfo] {
        var seen = Set<String>()
        return devices.compactMap { d in
            seen.insert(d.uniqueID).inserted ? CaptureDeviceInfo(id: d.uniqueID, name: d.localizedName) : nil
        }
    }
}

/// Picker of capture devices with a "System Default" entry ("") and a placeholder for a disconnected saved device.
struct DevicePicker: View {
    let title: String
    let devices: [CaptureDeviceInfo]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text("System Default").tag("")
            if !selection.isEmpty && !devices.contains(where: { $0.id == selection }) {
                Text("Unavailable device").tag(selection)
            }
            if !devices.isEmpty { Divider() }
            ForEach(devices) { Text($0.name).tag($0.id) }
        }
    }
}
