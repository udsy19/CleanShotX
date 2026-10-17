import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import ShotcraftCore

/// Studio editor palette (the window is always dark).
enum StudioTheme {
    static let window = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
    static let panel = NSColor(srgbRed: 0x23 / 255, green: 0x23 / 255, blue: 0x23 / 255, alpha: 1)
    static let track = NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1)
    static let segment = NSColor(srgbRed: 0x4A / 255, green: 0x4A / 255, blue: 0x4C / 255, alpha: 1)
    static let hairline = NSColor.white.withAlphaComponent(0.08)
}

extension Color {
    static let studioPanel = Color(nsColor: StudioTheme.panel)
    static let studioHairline = Color(nsColor: StudioTheme.hairline)
    static let studioControl = Color.white.opacity(0.07)
}

/// Left-rail panels in rail order, plus the contextual Zoom panel (shown while a zoom is selected).
enum SidebarTab: String, CaseIterable, Identifiable {
    case cursor, keystrokes, audio, camera, background, animations, zoom
    var id: String { rawValue }
    static let rail: [SidebarTab] = [.cursor, .keystrokes, .audio, .camera, .background, .animations]
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .cursor: "cursorarrow.rays"
        case .keystrokes: "command.square"
        case .audio: "speaker.wave.2.fill"
        case .camera: "video.fill"
        case .background: "photo"
        case .animations: "circle.dashed"
        case .zoom: "plus.magnifyingglass"
        }
    }
}

@MainActor
final class SidebarState: ObservableObject {
    @Published var tab: SidebarTab = .background
    /// Rail panel to return to when the contextual Zoom panel closes.
    var railTab: SidebarTab = .background
    /// Callbacks into the window controller.
    var thumbnail: (Double) async -> CGImage? = { _ in nil }
    var toggleCameraFullscreen: () -> Void = {}

    func showRail(_ tab: SidebarTab) { railTab = tab; self.tab = tab }
}

/// Icon rail (44 pt) + properties panel (245 pt).
struct SidebarView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state: SidebarState
    static let railWidth: CGFloat = 44
    static let panelWidth: CGFloat = 245
    static let transportHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(SidebarTab.rail) { tab in
                    RailButton(symbol: tab.symbol, help: tab.title, selected: state.tab == tab) { state.showRail(tab) }
                }
                Spacer(minLength: 0)
                // Cut tool, aligned with the transport bar under the preview.
                RailButton(symbol: "scissors", help: "Cut Tool (B) · Selection Tool (V)", selected: model.tool == .cut) {
                    model.tool = model.tool == .cut ? .selection : .cut
                }
                .frame(height: Self.transportHeight)
            }
            .padding(.top, 10)
            .frame(width: Self.railWidth)
            Rectangle().fill(Color.studioHairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch state.tab {
                    case .cursor: CursorPanel(model: model)
                    case .keystrokes: KeystrokesPanel(model: model)
                    case .audio: AudioPanel(model: model)
                    case .camera: CameraPanel(model: model, state: state)
                    case .background: BackgroundPanel(model: model)
                    case .animations: AnimationsPanel(model: model)
                    case .zoom: ZoomPanel(model: model, state: state)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: Self.panelWidth)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .background(Color.studioPanel)
        .environment(\.colorScheme, .dark)
    }
}

struct RailButton: View {
    let symbol: String
    let help: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Shared controls

/// A titled group: 11 pt secondary label, then its controls.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// "Show cursor" style row: a label with a trailing switch.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) { Text(title).frame(maxWidth: .infinity, alignment: .leading) }
            .toggleStyle(.switch).controlSize(.mini)
    }
}

/// Slider with a trailing value label.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var label: (Double) -> String
    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range)
            Text(label(value)).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 40, alignment: .trailing)
        }
    }
}

/// Two-choice segmented pair whose selected half is filled with the accent colour.
struct PairPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .foregroundStyle(selection == value ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selection == value ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.studioControl))
    }
}

/// 3×3 grid of small rounded tiles; the selected one is blue.
struct PositionGrid: View {
    @Binding var selection: GridPosition
    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 3)
        LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
            ForEach(GridPosition.allCases, id: \.self) { p in
                Button { selection = p } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selection == p ? Color.accentColor : Color.studioControl)
                        .frame(width: 30, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.studioHairline))
    }
}

struct NoteBox: View {
    let text: String
    var action: (String, () -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action.0, action: action.1) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.studioControl))
    }
}

func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
func multiplier(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))x" : String(format: "%.1fx", v) }

// MARK: - Cursor

struct CursorPanel: View {
    @ObservedObject var model: EditorModel
    private var cursor: CursorSettings { model.project.style.cursor }

    var body: some View {
        if model.events.cursor.isEmpty {
            NoteBox(text: "Cursor customization is only available for videos recorded in Studio Mode.")
        }
        PanelSection(title: "Cursor") {
            SwitchRow(title: "Show cursor", isOn: model.binding(\.style.cursor.show, "cursor-show"))
        }
        Group {
            PanelSection(title: "Size") {
                ValueSlider(value: model.binding(\.style.cursor.size, "cursor-size"), range: 0.5...4, label: multiplier)
            }
            PanelSection(title: "Style") {
                HStack(spacing: 8) {
                    ForEach(CursorStyle.allCases, id: \.self) { s in
                        CursorTile(style: s, selected: cursor.style == s) { model.update { $0.style.cursor.style = s } }
                    }
                }
            }
            PanelSection(title: "Motion") {
                PairPicker(selection: Binding(get: { cursor.isSmoothMotion }, set: { smooth in
                    model.update { $0.style.cursor.smoothing = smooth ? CursorSettings.smoothSmoothing : CursorSettings.naturalSmoothing }
                }), options: [(false, "Natural"), (true, "Smooth")])
            }
        }
        .disabled(!cursor.show)
        PanelSection(title: "Clicks") {
            Toggle("Press effect", isOn: model.binding(\.style.cursor.pressEffect, "cursor-press")).toggleStyle(.checkbox)
            Toggle("Ripple animation", isOn: Binding(get: { cursor.clickEffect == .ripple }, set: { on in
                model.update { $0.style.cursor.clickEffect = on ? .ripple : .none }
            })).toggleStyle(.checkbox)
            Group {
                LabeledPopup(title: "Color") {
                    Picker("", selection: Binding(get: { ClickColor.nearest(cursor.rippleColor) }, set: { c in
                        model.update { $0.style.cursor.rippleColor = c.rgba }
                    })) {
                        ForEach(ClickColor.allCases, id: \.self) { c in
                            Label { Text(c.title) } icon: { Image(nsImage: ColorDot.image(c.rgba)) }.tag(c)
                        }
                    }
                }
                LabeledPopup(title: "Style") {
                    Picker("", selection: model.binding(\.style.cursor.clickStyle, "cursor-click-style")) {
                        ForEach(ClickStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            .disabled(cursor.clickEffect != .ripple)
        }
        PanelSection(title: "Options") {
            Toggle("Hide cursor when not moving", isOn: model.binding(\.style.cursor.hideWhenIdle, "cursor-idle")).toggleStyle(.checkbox)
            Toggle("Hide cursor when typing", isOn: model.binding(\.style.cursor.hideWhenTyping, "cursor-typing")).toggleStyle(.checkbox)
        }
        .disabled(!cursor.show)
    }
}

/// 40 pt square tile previewing a cursor style; the selected tile has a 2 pt blue ring.
struct CursorTile: View {
    let style: CursorStyle
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.85))
                if let bmp = Artwork.shared.cursor(kind: .arrow, style: style, height: 44) {
                    Image(nsImage: NSImage(cgImage: bmp.image, size: NSSize(width: bmp.image.width / 2, height: bmp.image.height / 2)))
                }
            }
            .frame(width: 40, height: 40)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.studioHairline,
                                                                    lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(style.title)
    }
}

/// Title on the left, popup on the right.
struct LabeledPopup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            content().labelsHidden().fixedSize()
        }
    }
}

/// Small coloured circles for popup menu items.
enum ColorDot {
    @MainActor static func image(_ c: RGBAColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            NSColor(cgColor: c.cgColor)?.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}

// MARK: - Keystrokes

struct KeystrokesPanel: View {
    @ObservedObject var model: EditorModel
    private var keys: KeystrokeSettings { model.project.style.keystrokes }

    var body: some View {
        if !model.events.keystrokesCaptured {
            NoteBox(text: "Keystroke capture requires Accessibility permission. Enable it for future recordings.",
                    action: ("Open System Settings", { Permissions.openSettings(.accessibility) }))
        } else if model.events.keys.isEmpty {
            NoteBox(text: "No keystrokes were captured in this video.")
        }
        PanelSection(title: "Keystrokes") {
            SwitchRow(title: "Show keystrokes", isOn: model.binding(\.style.keystrokes.show, "keys-show"))
        }
        Group {
            PanelSection(title: "Size") {
                ValueSlider(value: model.binding(\.style.keystrokes.size, "keys-size"), range: 0.5...2.5, label: multiplier)
            }
            PanelSection(title: "Style") {
                Picker("", selection: model.binding(\.style.keystrokes.style, "keys-style")) {
                    ForEach(KeystrokeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            PanelSection(title: "Position") {
                PositionGrid(selection: model.binding(\.style.keystrokes.position, "keys-pos"))
            }
            PanelSection(title: "Options") {
                Picker("", selection: model.binding(\.style.keystrokes.displayAll, "keys-all")) {
                    Text("Show only command keys").tag(false)
                    Text("Show all keys").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
        }
        .disabled(!keys.show)
    }
}

// MARK: - Audio

struct AudioPanel: View {
    @ObservedObject var model: EditorModel
    private var rec: RecordingInfo { model.project.recording }
    private var audio: AudioSettings { model.project.style.audio }

    var body: some View {
        if !model.hasAudio {
            NoteBox(text: "This video has no audio.")
        }
        PanelSection(title: "Microphone") {
            if rec.hasMicrophone {
                SwitchRow(title: "Include microphone", isOn: model.binding(\.style.audio.includeMicrophone, "audio-mic-on"))
                Text("Microphone volume").foregroundStyle(.secondary)
                ValueSlider(value: model.binding(\.style.audio.microphoneVolume, "audio-mic"), range: 0...2, label: percent)
                    .disabled(!audio.includeMicrophone)
                if let name = rec.microphoneName { Text(name).font(.system(size: 11)).foregroundStyle(.tertiary) }
            } else {
                NoteBox(text: "No microphone was selected for this recording.")
            }
        }
        PanelSection(title: "System audio") {
            if rec.hasSystemAudio {
                SwitchRow(title: "Include system audio", isOn: model.binding(\.style.audio.includeSystemAudio, "audio-sys-on"))
                Text("System audio volume").foregroundStyle(.secondary)
                ValueSlider(value: model.binding(\.style.audio.systemVolume, "audio-sys"), range: 0...2, label: percent)
                    .disabled(!audio.includeSystemAudio)
            } else {
                NoteBox(text: "System audio was not recorded for this video.")
            }
        }
    }
}

// MARK: - Camera

struct CameraPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state: SidebarState
    private var cam: CameraSettings { model.project.style.camera }

    var body: some View {
        if !model.hasCamera {
            NoteBox(text: "No camera was recorded for this video. Choose a camera before recording in Studio Mode to use this option.")
        } else {
            PanelSection(title: "Camera") {
                SwitchRow(title: "Show camera", isOn: model.binding(\.style.camera.show, "cam-show"))
            }
            Group {
                PanelSection(title: "Size") {
                    ValueSlider(value: model.binding(\.style.camera.size, "cam-size"), range: 0.1...0.5, label: percent)
                }
                PanelSection(title: "Shape") {
                    Picker("", selection: model.binding(\.style.camera.shape, "cam-shape")) {
                        ForEach(CameraShape.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                PanelSection(title: "Position") {
                    PositionGrid(selection: model.binding(\.style.camera.position, "cam-pos"))
                }
                PanelSection(title: "Options") {
                    Toggle("Flip camera", isOn: model.binding(\.style.camera.flip, "cam-flip")).toggleStyle(.checkbox)
                    Toggle("Shrink camera on zoom", isOn: model.binding(\.style.camera.shrinkOnZoom, "cam-shrink")).toggleStyle(.checkbox)
                }
                PanelSection(title: "Full Screen") {
                    Button("Toggle Full Screen at Playhead") { state.toggleCameraFullscreen() }
                    Text("Click on camera to toggle Full Screen, or drag on the camera track.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!cam.show)
        }
    }
}

// MARK: - Background

enum WallpaperLibrary {
    /// Desktop pictures shipped with macOS (plus the current desktop).
    static let files: [URL] = {
        var out: [URL] = []
        if let screen = NSScreen.main, let current = NSWorkspace.shared.desktopImageURL(for: screen),
           ["heic", "jpg", "jpeg", "png", "tiff"].contains(current.pathExtension.lowercased()) { out.append(current) }
        let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        out += items.filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var seen = Set<String>()
        return Array(out.filter { seen.insert($0.path).inserted }.prefix(24))
    }()
}

struct ThumbnailImage: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color.studioControl
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: url) {
            let u = url
            let cg: CGImage? = await Task.detached(priority: .utility) {
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 120,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            if let cg { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }
}

struct Swatch<Content: View>: View {
    let selected: Bool
    let help: String
    var size: CGFloat = 38
    var radius: CGFloat = 8
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: action) {
            content()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(selected ? Color.accentColor : Color.studioHairline,
                                                                             lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel
    @State private var showAllWallpapers = false
    /// Plain colours: 2 rows of 9 (the last cell is the custom colour well).
    private static let colors: [RGBAColor] = [
        RGBAColor(r: 1, g: 1, b: 1), RGBAColor(r: 0.90, g: 0.90, b: 0.92), RGBAColor(r: 0.62, g: 0.62, b: 0.65),
        RGBAColor(r: 0.33, g: 0.33, b: 0.36), RGBAColor(r: 0.11, g: 0.11, b: 0.13), RGBAColor(r: 0, g: 0, b: 0),
        RGBAColor(r: 1.0, g: 0.27, b: 0.23), RGBAColor(r: 1.0, g: 0.62, b: 0.04), RGBAColor(r: 1.0, g: 0.84, b: 0.04),
        RGBAColor(r: 0.19, g: 0.82, b: 0.35), RGBAColor(r: 0.0, g: 0.78, b: 0.75), RGBAColor(r: 0.39, g: 0.82, b: 1.0),
        RGBAColor(r: 0.04, g: 0.52, b: 1.0), RGBAColor(r: 0.37, g: 0.36, b: 0.90), RGBAColor(r: 0.69, g: 0.32, b: 0.87),
        RGBAColor(r: 1.0, g: 0.22, b: 0.37), RGBAColor(r: 0.64, g: 0.52, b: 0.37),
    ]
    private let wide = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 5)
    private let narrow = Array(repeating: GridItem(.fixed(20), spacing: 4), count: 9)

    private var bg: StudioBackground { model.project.style.background }
    private func set(_ b: StudioBackground) { model.update { $0.style.background = b } }
    private static let wallpaperPreview = 9

    var body: some View {
        PanelSection(title: "Background") {
            LazyVGrid(columns: wide, alignment: .leading, spacing: 6) {
                Swatch(selected: bg.isNone, help: "None", action: { set(.none) }) {
                    ZStack { Color.studioControl; Image(systemName: "nosign").foregroundStyle(.secondary) }
                }
                ForEach(GradientPreset.allCases, id: \.self) { g in gradientSwatch(g) }
            }
        }
        PanelSection(title: "Wallpapers") {
            LazyVGrid(columns: wide, alignment: .leading, spacing: 6) {
                ForEach(Array(WallpaperLibrary.files.prefix(showAllWallpapers ? 24 : Self.wallpaperPreview)), id: \.self) { url in
                    Swatch(selected: bg == .wallpaper(path: url.path), help: url.deletingPathExtension().lastPathComponent,
                           action: { set(.wallpaper(path: url.path)) }) { ThumbnailImage(url: url) }
                }
                Swatch(selected: { if case .image = bg { return true }; return false }(), help: "Choose Image…", action: chooseImage) {
                    if case .image(let name) = bg { ThumbnailImage(url: model.package.resolve(backgroundFile: name)) }
                    else { ZStack { Color.studioControl; Image(systemName: "plus").foregroundStyle(.secondary) } }
                }
            }
            if WallpaperLibrary.files.count > Self.wallpaperPreview {
                Button(showAllWallpapers ? "Show less" : "Show more") { showAllWallpapers.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        PanelSection(title: "Plain color") {
            LazyVGrid(columns: narrow, alignment: .leading, spacing: 4) {
                ForEach(Self.colors, id: \.self) { c in
                    Swatch(selected: bg == .color(c), help: "Color", size: 20, radius: 5, action: { set(.color(c)) }) { Color(cgColor: c.cgColor) }
                }
                ColorPicker("", selection: Binding(
                    get: { if case .color(let c) = bg { return Color(cgColor: c.cgColor) }; return .gray },
                    set: { col in
                        let ns = NSColor(col).usingColorSpace(.sRGB) ?? .gray
                        model.update(coalesce: "bg-color") { $0.style.background = .color(RGBAColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)) }
                    }), supportsOpacity: false)
                .labelsHidden().frame(width: 20, height: 20).help("Custom Color")
            }
        }
        PanelSection(title: "Aspect Ratio") {
            Picker("", selection: model.binding(\.style.aspectRatio, "aspect")) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Group {
            PanelSection(title: "Padding") {
                ValueSlider(value: model.binding(\.style.padding, "padding"), range: 0...0.3, label: { percent($0 / 0.3) })
            }
            PanelSection(title: "Shadow") {
                ValueSlider(value: model.binding(\.style.shadow, "shadow"), range: 0...1, label: percent)
            }
            PanelSection(title: "Corners") {
                ValueSlider(value: model.binding(\.style.cornerRadius, "corners"), range: 0...StudioStyle.maxCornerRadius,
                            label: { percent($0 / StudioStyle.maxCornerRadius) })
            }
        }
        .disabled(bg.isNone)
        PanelSection(title: "Inset") {
            ValueSlider(value: model.binding(\.style.inset, "inset"), range: 0...0.15, label: { percent($0 / 0.15) })
        }
    }

    private func gradientSwatch(_ g: GradientPreset) -> some View {
        Swatch(selected: bg == .gradient(g), help: "Gradient", action: { set(.gradient(g)) }) {
            LinearGradient(colors: g.colors.map { Color(cgColor: $0.cgColor) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = "background-\(UUID().uuidString.prefix(8)).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)"
        do {
            try FileManager.default.copyItem(at: url, to: model.package.resolve(backgroundFile: name))
            set(.image(fileName: name))
        } catch {
            Alerts.error("Something went wrong saving your file.", error)
        }
    }
}

// MARK: - Animations

struct AnimationsPanel: View {
    @ObservedObject var model: EditorModel
    private var zoom: ZoomSettings { model.project.style.zoom }

    static func blurTitle(_ v: Double) -> String {
        switch v {
        case ..<0.01: "Off"
        case ..<0.4: "Low"
        case ..<0.75: "Medium"
        default: "High"
        }
    }

    var body: some View {
        PanelSection(title: "Motion Blur") {
            ValueSlider(value: model.binding(\.style.zoom.motionBlur, "zoom-blur"), range: 0...1, label: Self.blurTitle)
        }
        PanelSection(title: "Zoom animations") {
            PairPicker(selection: Binding(get: { zoom.isDynamic }, set: { d in model.update { $0.style.zoom.setDynamic(d) } }),
                       options: [(false, "Smooth"), (true, "Dynamic")])
        }
        PanelSection(title: "Automatic zoom") {
            Toggle("Zoom in on clicks in new recordings", isOn: model.binding(\.style.zoom.autoZoom, "zoom-auto")).toggleStyle(.checkbox)
            Toggle("New zooms follow the cursor", isOn: model.binding(\.style.zoom.followCursorByDefault, "zoom-follow"))
                .toggleStyle(.checkbox).disabled(model.events.cursor.isEmpty)
            Text("Default zoom level").foregroundStyle(.secondary)
            ValueSlider(value: model.binding(\.style.zoom.defaultLevel, "zoom-default"), range: 1.1...5, label: percent)
            HStack {
                Button("Regenerate Zooms") { model.regenerateZooms() }.disabled(model.events.clicks.isEmpty)
                Button("Remove All") { model.removeAllZooms() }.disabled(model.project.zooms.isEmpty)
            }
        }
    }
}

// MARK: - Zoom (contextual)

/// Drag the focus rectangle over a frame thumbnail to choose a zoom's focus point (FLZoomPositionControl).
struct ZoomPositionControl: View {
    let image: NSImage?
    let aspect: CGFloat
    let level: Double
    @Binding var focus: NPoint

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let w = size.width / CGFloat(max(level, 1)), h = size.height / CGFloat(max(level, 1))
            let cx = min(max(CGFloat(focus.x) * size.width, w / 2), size.width - w / 2)
            let cy = min(max(CGFloat(focus.y) * size.height, h / 2), size.height - h / 2)
            ZStack(alignment: .topLeading) {
                if let image { Image(nsImage: image).resizable() } else { Color.black }
                Color.black.opacity(0.45)
                    .mask(Rectangle().overlay(Rectangle().frame(width: w, height: h).position(x: cx, y: cy).blendMode(.destinationOut)).compositingGroup())
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: w, height: h).position(x: cx, y: cy)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                focus = NPoint(x: Double(v.location.x / size.width), y: Double(v.location.y / size.height)).clamped
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ZoomPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state: SidebarState
    @State private var thumb: NSImage?
    @State private var showAnimation = false

    private var selected: ZoomSegment? {
        if case .zoom(let id) = model.selection { return model.project.zooms.first { $0.id == id } }
        return nil
    }

    var body: some View {
        if let z = selected {
            HStack {
                Text("Zoom").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.selection = .none } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close")
            }
            PanelSection(title: "Zoom level") {
                ValueSlider(value: model.zoomBinding(z.id, \.level, fallback: 2), range: 1.1...5, label: percent)
                Button("Apply Zoom Level to All") { model.applyZoomLevelToAll() }
            }
            PanelSection(title: "Zoom mode") {
                PairPicker(selection: model.zoomBinding(z.id, \.mode, fallback: .manual),
                           options: [(ZoomMode.followCursor, "Follow Cursor"), (ZoomMode.manual, "Manual")])
                    .disabled(model.events.cursor.isEmpty)
                if model.events.cursor.isEmpty {
                    Text("Record your video in Studio Mode to use this option.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if z.mode == .manual {
                    ZoomPositionControl(image: thumb,
                                        aspect: CGFloat(model.project.recording.pixelWidth) / CGFloat(max(model.project.recording.pixelHeight, 1)),
                                        level: z.level, focus: model.zoomBinding(z.id, \.focus, fallback: .center))
                        .task(id: z.id) {
                            thumb = nil
                            if let cg = await state.thumbnail((z.start + z.end) / 2) { thumb = NSImage(cgImage: cg, size: .zero) }
                        }
                }
            }
            PanelSection(title: "Animation") {
                Button("Animation Settings") { showAnimation.toggle() }
                    .popover(isPresented: $showAnimation, arrowEdge: .trailing) { animationSettings.padding(14).frame(width: 240) }
            }
            HStack {
                Button("Split at Playhead") { model.splitZoomAtPlayhead() }
                Button("Remove", role: .destructive) { model.deleteSelection() }
            }
        } else {
            NoteBox(text: "Select a zoom on the timeline to edit it, or click the zoom track to add one.")
        }
    }

    private var animationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSection(title: "Speed") {
                Picker("", selection: model.binding(\.style.zoom.animation, "zoom-anim")) {
                    ForEach(ZoomAnimationStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            PanelSection(title: "Easing") {
                Picker("", selection: model.binding(\.style.zoom.easing, "zoom-ease")) {
                    ForEach(ZoomEasing.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            Text("Applies to every zoom in this video.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }
}
