import AppKit
import AVFoundation
import Combine
import SwiftUI
import ShotcraftCore

// MARK: - Pane scaffold

/// A grouped form with the pane's title, used by every pane.
struct PaneForm<Content: View>: View {
    let pane: PreferencesPane
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
    }
}

/// Secondary explanatory text under a control.
struct HelpText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Toggle with an optional help line underneath.
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

/// Polls permission state while a view showing it is visible (System Settings changes don't notify us).
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    private var timer: Timer?
    private var observers = 0

    init() { refresh() }

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
            Permissions.requestAccessibility()
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
        var videoTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        videoTypes.append(.deskViewCamera)
        let video = AVCaptureDevice.DiscoverySession(deviceTypes: videoTypes, mediaType: .video, position: .unspecified)
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
