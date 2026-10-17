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
    /// Hosts a SwiftUI view (which draws its own background) in a transparent borderless panel.
    static func panel<V: View>(_ view: V) -> StudioPanel {
        let host = NSHostingView(rootView: view)
        let p = StudioPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize))
        p.contentView = host
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

/// Dark behind-window glass for SwiftUI blocks in transparent panels.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.layer?.cornerRadius = cornerRadius }
}

extension View {
    /// A dark-glass block with a 1 px inner highlight (recorder panel style).
    func glassBlock(_ radius: CGFloat) -> some View {
        background(GlassBackground(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.14)))
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

/// Pre-record panel (RecorderSettingsView, Studio flavour): a settings row of device toggles over a
/// "Record in Studio Mode" pill. Active toggles are full white with a small tick; inactive ones are dimmed.
struct PreRecordBar: View {
    @ObservedObject var options: PreRecordOptions
    static let width: CGFloat = 227

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                cell(active: options.microphoneID != nil, help: options.microphones.first { $0.id == options.microphoneID }?.name ?? "Microphone off") {
                    Menu {
                        Button { options.microphoneID = nil } label: { check(options.microphoneID == nil, "No Microphone") }
                        Divider()
                        ForEach(options.microphones) { m in
                            Button { options.microphoneID = m.id } label: { check(options.microphoneID == m.id, m.name) }
                        }
                    } label: { Image(systemName: "mic") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                }
                divider
                cell(active: options.systemAudio, help: "Record system audio") {
                    Button { options.systemAudio.toggle() } label: { Image(systemName: "speaker.wave.2") }.buttonStyle(.plain)
                }
                divider
                cell(active: options.cameraID != nil, help: options.cameras.first { $0.id == options.cameraID }?.name ?? "Camera off") {
                    Menu {
                        Button { options.cameraID = nil; options.onCameraChange(nil) } label: { check(options.cameraID == nil, "No Camera") }
                        Divider()
                        ForEach(options.cameras) { c in
                            Button { options.cameraID = c.id; options.onCameraChange(c.id) } label: { check(options.cameraID == c.id, c.name) }
                        }
                    } label: { Image(systemName: "video") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                }
                divider
                cell(active: options.keystrokes, help: "Capture keystrokes (requires Accessibility)") {
                    Button { options.keystrokes.toggle() } label: { Image(systemName: "command.square") }.buttonStyle(.plain)
                }
                divider
                cell(active: true, showsTick: false, help: "Cancel (Esc)") {
                    Button(action: options.onCancel) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            .frame(height: 50)
            .glassBlock(16)

            Button(action: options.onStart) {
                HStack(spacing: 8) {
                    Image(systemName: "movieclapper.fill").frame(width: 20)
                    Text("Record in Studio Mode").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    Text("↩").foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .frame(height: 37)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .glassBlock(18.5)
            .help("Start recording (Return)")
        }
        .frame(width: Self.width)
        .foregroundStyle(.white)
        .padding(6)
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }

    private func cell<C: View>(active: Bool, showsTick: Bool = true, help: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 3) {
            content()
                .font(.system(size: 16, weight: .regular))
                .frame(width: 30, height: 22)
            Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
                .opacity(showsTick && active ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(active ? Color.white : Color.white.opacity(0.55))
        .contentShape(Rectangle())
        .help(help)
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
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

/// Recording controls (RecorderControlsView): dark pill with stop + red timer, pause/resume, restart, delete
/// and a drag grip, separated by hairlines. The whole pill drags the panel.
struct RecordingControlsBar: View {
    @ObservedObject var model: RecordingControlsModel
    var body: some View {
        HStack(spacing: 0) {
            Button(action: model.onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle").font(.system(size: 19, weight: .medium))
                    Text(model.elapsed).font(.system(size: 15, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Color(nsColor: .systemRed).opacity(model.paused ? 0.6 : 1))
                .frame(minWidth: 80, maxHeight: .infinity)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Stop Recording")
            separator
            icon(model.paused ? "play.circle" : "pause.circle", model.paused ? "Resume" : "Pause", model.onPauseResume)
            separator
            icon("arrow.counterclockwise", "Restart Recording", model.onRestart)
            separator
            icon("trash", "Delete Recording", model.onDelete)
            separator
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5)).frame(width: 28).help("Drag to move")
        }
        .frame(height: 40)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.086).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.12)))
        .padding(4)
    }

    private var separator: some View { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 20) }

    private func icon(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - Countdown

@MainActor
final class CountdownModel: ObservableObject {
    @Published var remaining = 3
    var onCancel: () -> Void = {}
}

/// 80 pt black disc with the big digit and a ring that fills each second; hovering shows a cancel button.
struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    @State private var arc: CGFloat = 0
    @State private var hover = false

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.9))
            Circle().trim(from: 0, to: arc)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(4)
            if hover {
                Button(action: model.onCancel) { Image(systemName: "xmark").font(.system(size: 26, weight: .bold)) }
                    .buttonStyle(.plain).help("Cancel (Esc)")
            } else {
                Text("\(model.remaining)").font(.system(size: 44, weight: .bold)).monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .frame(width: 80, height: 80)
        .onHover { hover = $0 }
        .onAppear(perform: restartArc)
        .onChange(of: model.remaining) { restartArc() }
    }

    private func restartArc() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { arc = 0 }
        DispatchQueue.main.async { withAnimation(.linear(duration: 1)) { arc = 1 } }
    }
}

@MainActor
final class CountdownWindow {
    private var panel: NSPanel?
    private var timer: Timer?
    private let model = CountdownModel()
    private var completion: ((Bool) -> Void)?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?

    func run(seconds: Int, over rect: CGRect, completion: @escaping (Bool) -> Void) {
        guard seconds > 0 else { completion(true); return }
        self.completion = completion
        model.remaining = seconds
        model.onCancel = { [weak self] in self?.finish(false) }
        let size: CGFloat = 80
        let p = NSPanel(contentRect: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .screenSaver
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: CountdownView(model: model))
        p.appearance = NSAppearance(named: .darkAqua)
        p.orderFrontRegardless()
        panel = p
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
        model.remaining -= 1
        if model.remaining <= 0 { finish(true); return }
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
        let d: CGFloat = min(160, max(96, min(rect.width, rect.height) * 0.25))
        super.init(contentRect: NSRect(x: rect.maxX - d - 16, y: rect.minY + 16, width: d, height: d),
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
        layer.borderColor = NSColor.white.cgColor
        layer.borderWidth = 3
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        view.layer?.addSublayer(layer)
        contentView = view
    }
}
