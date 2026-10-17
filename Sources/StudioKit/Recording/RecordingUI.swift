import AppKit
import SwiftUI
import AVFoundation
import ShotcraftCore

/// Borderless panel that can become key (for menus / keyboard) without activating the app.
final class StudioPanel: NSPanel {
    var onCancel: (() -> Void)?
    init(contentRect: NSRect, level: NSWindow.Level = .statusBar) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        self.level = level
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
enum PanelFactory {
    /// Hosts a SwiftUI view in a rounded HUD-material panel.
    static func panel<V: View>(_ view: V, cornerRadius: CGFloat = 14) -> StudioPanel {
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        let size = host.fittingSize
        let p = StudioPanel(contentRect: NSRect(origin: .zero, size: size))
        p.contentView = fx
        p.appearance = NSAppearance(named: .darkAqua)
        return p
    }

    /// Places a panel centered under `rect` (inside it if there's no room below), on `screen`.
    static func place(_ panel: NSWindow, below rect: CGRect, on screen: NSScreen, gap: CGFloat = 14) {
        let size = panel.frame.size
        let vis = screen.visibleFrame
        var y = rect.minY - gap - size.height
        if y < vis.minY + 8 { y = max(rect.minY + gap * 2, vis.minY + 8) }
        let x = min(max(rect.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: min(y, vis.maxY - size.height - 8)))
    }
}

// MARK: - Area outline

/// Thin outline around the recorded area (our windows are excluded from capture).
final class AreaOutlineWindow: NSWindow {
    init(rect: CGRect) {
        super.init(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = OutlineView()
    }
    final class OutlineView: NSView {
        var dashed = true { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 1.5
            if dashed { path.setLineDash([6, 4], count: 2, phase: 0) }
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.stroke()
            let inner = NSBezierPath(rect: bounds.insetBy(dx: 2.5, dy: 2.5))
            inner.lineWidth = 0.5
            NSColor.black.withAlphaComponent(0.35).setStroke()
            inner.stroke()
        }
    }
    func setRecording(_ recording: Bool) { (contentView as? OutlineView)?.dashed = !recording }
}

// MARK: - Pre-record bar

struct DeviceChoice: Identifiable, Hashable { var id: String; var name: String }

@MainActor
final class PreRecordOptions: ObservableObject {
    @Published var microphoneID: String?
    @Published var systemAudio: Bool
    @Published var cameraID: String?
    @Published var keystrokes: Bool
    let microphones: [DeviceChoice]
    let cameras: [DeviceChoice]
    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}
    var onCameraChange: (String?) -> Void = { _ in }

    init() {
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        cameras = CameraRecorder.devices().map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        let mic = Defaults[.microphoneDeviceID]
        microphoneID = Defaults[.recordMicrophone] ? (microphones.first { $0.id == mic }?.id ?? microphones.first?.id) : nil
        systemAudio = Defaults[.recordSystemAudio]
        let cam = Defaults[.cameraDeviceID]
        cameraID = Defaults[.recordCamera] ? (cameras.first { $0.id == cam }?.id ?? cameras.first?.id) : nil
        keystrokes = Defaults[.studioRecordKeystrokes]
    }

    func persist() {
        Defaults[.recordMicrophone] = microphoneID != nil
        if let m = microphoneID { Defaults[.microphoneDeviceID] = m }
        Defaults[.recordSystemAudio] = systemAudio
        Defaults[.recordCamera] = cameraID != nil
        if let c = cameraID { Defaults[.cameraDeviceID] = c }
        Defaults[.studioRecordKeystrokes] = keystrokes
    }
}

struct PreRecordBar: View {
    @ObservedObject var options: PreRecordOptions

    var body: some View {
        HStack(spacing: 6) {
            Button(action: options.onCancel) { Image(systemName: "xmark").frame(width: 26, height: 26) }
                .buttonStyle(BarButtonStyle()).help("Cancel (Esc)")
            Divider().frame(height: 22)
            Menu {
                Button { options.microphoneID = nil } label: { check(options.microphoneID == nil, "No Microphone") }
                Divider()
                ForEach(options.microphones) { m in
                    Button { options.microphoneID = m.id } label: { check(options.microphoneID == m.id, m.name) }
                }
            } label: {
                Image(systemName: options.microphoneID == nil ? "mic.slash.fill" : "mic.fill")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34, height: 26)
            .help(options.microphones.first { $0.id == options.microphoneID }?.name ?? "Microphone off")
            Toggle(isOn: $options.systemAudio) { Image(systemName: options.systemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill") }
                .toggleStyle(BarToggleStyle()).help("Record system audio")
            Menu {
                Button { options.cameraID = nil; options.onCameraChange(nil) } label: { check(options.cameraID == nil, "No Camera") }
                Divider()
                ForEach(options.cameras) { c in
                    Button { options.cameraID = c.id; options.onCameraChange(c.id) } label: { check(options.cameraID == c.id, c.name) }
                }
            } label: {
                Image(systemName: options.cameraID == nil ? "video.slash.fill" : "video.fill")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 34, height: 26)
            .help(options.cameras.first { $0.id == options.cameraID }?.name ?? "Record camera")
            Toggle(isOn: $options.keystrokes) { Image(systemName: "keyboard") }
                .toggleStyle(BarToggleStyle()).help("Capture keystrokes (requires Accessibility)")
            Divider().frame(height: 22)
            Button(action: options.onStart) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    Text("Start Recording").fontWeight(.semibold)
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain).keyboardShortcut(.defaultAction).help("Start recording (Return)")
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .foregroundStyle(.white)
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.001)))
    }
}

struct BarToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label.frame(width: 30, height: 26)
                .foregroundStyle(configuration.isOn ? Color.white : Color.white.opacity(0.45))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(configuration.isOn ? 0.16 : 0.001)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recording controls

@MainActor
final class RecordingControlsModel: ObservableObject {
    @Published var elapsed = "0:00"
    @Published var paused = false
    var onStop: () -> Void = {}
    var onPauseResume: () -> Void = {}
    var onRestart: () -> Void = {}
    var onDelete: () -> Void = {}
}

struct RecordingControlsBar: View {
    @ObservedObject var model: RecordingControlsModel
    var body: some View {
        HStack(spacing: 4) {
            Button(action: model.onStop) {
                RoundedRectangle(cornerRadius: 3).fill(Color.red).frame(width: 12, height: 12).frame(width: 30, height: 28)
            }
            .buttonStyle(BarButtonStyle()).help("Stop Recording")
            Text(model.elapsed).font(.system(size: 13, weight: .medium).monospacedDigit()).frame(minWidth: 44)
                .foregroundStyle(model.paused ? Color.white.opacity(0.5) : .white)
            Button(action: model.onPauseResume) {
                Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 30, height: 28)
            }
            .buttonStyle(BarButtonStyle()).help(model.paused ? "Resume" : "Pause")
            Button(action: model.onRestart) { Image(systemName: "arrow.counterclockwise").frame(width: 30, height: 28) }
                .buttonStyle(BarButtonStyle()).help("Restart Recording")
            Button(action: model.onDelete) { Image(systemName: "trash").frame(width: 30, height: 28) }
                .buttonStyle(BarButtonStyle()).help("Delete Recording")
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .foregroundStyle(.white)
    }
}

// MARK: - Countdown

@MainActor
final class CountdownWindow {
    private var panel: NSPanel?
    private var timer: Timer?
    private var remaining = 0
    private var label: NSTextField?
    private var completion: ((Bool) -> Void)?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?

    func run(seconds: Int, over rect: CGRect, completion: @escaping (Bool) -> Void) {
        guard seconds > 0 else { completion(true); return }
        self.completion = completion
        remaining = seconds
        let size: CGFloat = 132
        let p = NSPanel(contentRect: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .screenSaver; p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = size / 2; fx.layer?.masksToBounds = true
        let l = NSTextField(labelWithString: "\(seconds)")
        l.font = .systemFont(ofSize: 64, weight: .semibold)
        l.textColor = .white
        l.alignment = .center
        l.frame = NSRect(x: 0, y: (size - 80) / 2, width: size, height: 80)
        fx.addSubview(l)
        p.contentView = fx
        p.appearance = NSAppearance(named: .darkAqua)
        p.orderFrontRegardless()
        panel = p; label = l
        Sound.play(.countdownTick)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.finish(false) } }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.finish(false) }
            return nil
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 { finish(true); return }
        label?.stringValue = "\(remaining)"
        Sound.play(.countdownTick)
    }

    func finish(_ ok: Bool) {
        timer?.invalidate(); timer = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        panel?.orderOut(nil); panel = nil
        let c = completion; completion = nil
        c?(ok)
    }
}

// MARK: - Camera preview bubble

/// Live camera bubble shown while preparing/recording (excluded from the capture like all our windows).
final class CameraBubbleWindow: NSPanel {
    init(session: AVCaptureSession, near rect: CGRect) {
        let d: CGFloat = 150
        super.init(contentRect: NSRect(x: rect.maxX - d - 20, y: rect.minY + 20, width: d, height: d),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .statusBar
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.cornerRadius = d / 2
        layer.masksToBounds = true
        layer.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        layer.borderWidth = 2
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        view.layer?.addSublayer(layer)
        contentView = view
    }
}
