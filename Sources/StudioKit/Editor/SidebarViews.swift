import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import ShotcraftCore

enum SidebarTab: String, CaseIterable, Identifiable {
    case background, cursor, zoom, camera, keystrokes, audio
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .background: "photo"
        case .cursor: "cursorarrow"
        case .zoom: "plus.magnifyingglass"
        case .camera: "web.camera"
        case .keystrokes: "keyboard"
        case .audio: "speaker.wave.2"
        }
    }
}

@MainActor
final class SidebarState: ObservableObject {
    @Published var tab: SidebarTab = .background
    /// Callbacks into the window controller.
    var thumbnail: (Double) async -> CGImage? = { _ in nil }
    var toggleCameraFullscreen: () -> Void = {}
}

struct SidebarView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state: SidebarState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SidebarTab.allCases) { tab in
                    Button { state.tab = tab } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .foregroundStyle(state.tab == tab ? Color.accentColor : Color.secondary)
                            .background(RoundedRectangle(cornerRadius: 7).fill(state.tab == tab ? Color.accentColor.opacity(0.15) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(state.tab.title).font(.headline)
                    switch state.tab {
                    case .background: BackgroundPanel(model: model)
                    case .cursor: CursorPanel(model: model)
                    case .zoom: ZoomPanel(model: model, state: state)
                    case .camera: CameraPanel(model: model, state: state)
                    case .keystrokes: KeystrokesPanel(model: model)
                    case .audio: AudioPanel(model: model)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Shared controls

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

struct NoteBox: View {
    let text: String
    var action: (String, () -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            if let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

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
            Color.secondary.opacity(0.15)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .task(id: url) {
            let u = url
            let cg: CGImage? = await Task.detached(priority: .utility) {
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 160,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            if let cg { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }
}

struct Swatch<Content: View>: View {
    let selected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                                                        lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel
    @State private var showAllWallpapers = false
    private let colors: [RGBAColor] = [
        RGBAColor(r: 1, g: 1, b: 1), RGBAColor(r: 0.93, g: 0.93, b: 0.95), RGBAColor(r: 0.11, g: 0.11, b: 0.13),
        RGBAColor(r: 0.0, g: 0.48, b: 1.0), RGBAColor(r: 0.2, g: 0.78, b: 0.35), RGBAColor(r: 1.0, g: 0.62, b: 0.04),
        RGBAColor(r: 1.0, g: 0.23, b: 0.19),
    ]
    private let grid = [GridItem(.adaptive(minimum: 40, maximum: 44), spacing: 8)]

    private var bg: StudioBackground { model.project.style.background }
    private func set(_ b: StudioBackground) { model.update { $0.style.background = b } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                Swatch(selected: bg.isNone, help: "None", action: { set(.none) }) {
                    ZStack { Color.secondary.opacity(0.12); Image(systemName: "nosign").foregroundStyle(.secondary) }
                }
                ForEach(GradientPreset.allCases, id: \.self) { g in
                    Swatch(selected: bg == .gradient(g), help: "Gradient", action: { set(.gradient(g)) }) {
                        LinearGradient(colors: g.colors.map { Color(cgColor: $0.cgColor) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            }
            Text("Colors").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                ForEach(colors, id: \.self) { c in
                    Swatch(selected: bg == .color(c), help: "Color", action: { set(.color(c)) }) { Color(cgColor: c.cgColor) }
                }
                ColorPicker("", selection: Binding(
                    get: { if case .color(let c) = bg { return Color(cgColor: c.cgColor) }; return .gray },
                    set: { col in
                        let ns = NSColor(col).usingColorSpace(.sRGB) ?? .gray
                        model.update(coalesce: "bg-color") { $0.style.background = .color(RGBAColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)) }
                    }), supportsOpacity: false)
                .labelsHidden().frame(width: 40, height: 40)
            }
            HStack {
                Text("Wallpapers").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if WallpaperLibrary.files.count > 7 {
                    Button(showAllWallpapers ? "Show Less" : "Show All") { showAllWallpapers.toggle() }.buttonStyle(.link).font(.caption)
                }
            }
            LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                ForEach(Array(WallpaperLibrary.files.prefix(showAllWallpapers ? 24 : 7)), id: \.self) { url in
                    Swatch(selected: bg == .wallpaper(path: url.path), help: url.deletingPathExtension().lastPathComponent,
                           action: { set(.wallpaper(path: url.path)) }) { ThumbnailImage(url: url) }
                }
                Swatch(selected: { if case .image = bg { return true }; return false }(), help: "Choose Image…", action: chooseImage) {
                    if case .image(let name) = bg { ThumbnailImage(url: model.package.resolve(backgroundFile: name)) }
                    else { ZStack { Color.secondary.opacity(0.12); Image(systemName: "plus").foregroundStyle(.secondary) } }
                }
            }
            Divider()
            Picker("Aspect ratio", selection: model.binding(\.style.aspectRatio, "aspect")) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            SliderRow(title: "Padding", value: model.binding(\.style.padding, "padding"), range: 0...0.3, format: percent)
                .disabled(bg.isNone)
            SliderRow(title: "Corners", value: model.binding(\.style.cornerRadius, "corners"), range: 0...60)
                .disabled(bg.isNone)
            SliderRow(title: "Shadow", value: model.binding(\.style.shadow, "shadow"), range: 0...1, format: percent)
                .disabled(bg.isNone)
            SliderRow(title: "Inset", value: model.binding(\.style.inset, "inset"), range: 0...0.15, format: percent)
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

// MARK: - Cursor

struct CursorPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.events.cursor.isEmpty {
                NoteBox(text: "Cursor customization is only available for videos recorded in Studio Mode.")
            }
            Toggle("Show cursor", isOn: model.binding(\.style.cursor.show, "cursor-show"))
            Group {
                Picker("Style", selection: model.binding(\.style.cursor.style, "cursor-style")) {
                    ForEach(CursorStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Size", value: model.binding(\.style.cursor.size, "cursor-size"), range: 0.5...4,
                          format: { String(format: "%.1f×", $0) })
                SliderRow(title: "Smoothing", value: model.binding(\.style.cursor.smoothing, "cursor-smooth"), range: 0...1, format: percent)
                Toggle("Hide cursor when not moving", isOn: model.binding(\.style.cursor.hideWhenIdle, "cursor-idle"))
                Toggle("Hide cursor when typing", isOn: model.binding(\.style.cursor.hideWhenTyping, "cursor-typing"))
                Toggle("Press effect", isOn: model.binding(\.style.cursor.pressEffect, "cursor-press"))
            }
            .disabled(!model.project.style.cursor.show)
            Divider()
            Picker("Click effect", selection: model.binding(\.style.cursor.clickEffect, "cursor-click")) {
                ForEach(ClickEffect.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if model.project.style.cursor.clickEffect == .ripple {
                ColorPicker("Ripple color", selection: Binding(
                    get: { Color(cgColor: model.project.style.cursor.rippleColor.cgColor) },
                    set: { col in
                        let ns = NSColor(col).usingColorSpace(.sRGB) ?? .white
                        model.update(coalesce: "ripple-color") {
                            $0.style.cursor.rippleColor = RGBAColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
                        }
                    }))
            }
        }
    }
}

// MARK: - Zoom

/// Drag the spotlight over a frame thumbnail to choose a zoom's focus point (FLZoomPositionControl).
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
                Circle().fill(Color.white).frame(width: 7, height: 7).position(x: cx, y: cy)
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

    private var selected: ZoomSegment? {
        if case .zoom(let id) = model.selection { return model.project.zooms.first { $0.id == id } }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let z = selected {
                Text("Selected Zoom").font(.subheadline).foregroundStyle(.secondary)
                SliderRow(title: "Zoom level", value: model.zoomBinding(z.id, \.level, fallback: 2), range: 1.1...5,
                          format: { String(format: "%.1f×", $0) })
                Picker("Mode", selection: model.zoomBinding(z.id, \.mode, fallback: .manual)) {
                    ForEach(ZoomMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.events.cursor.isEmpty)
                if model.events.cursor.isEmpty {
                    Text("Follow Cursor is only available for videos recorded in Studio Mode.").font(.caption).foregroundStyle(.secondary)
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
                HStack {
                    Button("Split at Playhead") { model.splitZoomAtPlayhead() }
                    Button("Delete", role: .destructive) { model.deleteSelection() }
                }
                .controlSize(.small)
                Divider()
            } else {
                NoteBox(text: "Select a zoom on the timeline to edit its level and position, or click the zoom track to add one.")
            }
            SliderRow(title: "Default zoom level", value: model.binding(\.style.zoom.defaultLevel, "zoom-default"), range: 1.1...5,
                      format: { String(format: "%.1f×", $0) })
            Toggle("Auto zoom on clicks", isOn: model.binding(\.style.zoom.autoZoom, "zoom-auto"))
            Toggle("New zooms follow the cursor", isOn: model.binding(\.style.zoom.followCursorByDefault, "zoom-follow"))
                .disabled(model.events.cursor.isEmpty)
            HStack {
                Button("Apply Zoom Level to All") { model.applyZoomLevelToAll() }.disabled(model.project.zooms.isEmpty)
                Button("Remove All Zooms") { model.removeAllZooms() }.disabled(model.project.zooms.isEmpty)
            }
            .controlSize(.small)
            Button("Regenerate Zooms from Clicks") { model.regenerateZooms() }
                .controlSize(.small).disabled(model.events.clicks.isEmpty)
            Divider()
            Text("Animation Settings").font(.subheadline).foregroundStyle(.secondary)
            Picker("Speed", selection: model.binding(\.style.zoom.animation, "zoom-anim")) {
                ForEach(ZoomAnimationStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Easing", selection: model.binding(\.style.zoom.easing, "zoom-ease")) {
                ForEach(ZoomEasing.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            SliderRow(title: "Motion blur", value: model.binding(\.style.zoom.motionBlur, "zoom-blur"), range: 0...1, format: percent)
        }
    }
}

// MARK: - Camera

struct CameraPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state: SidebarState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.hasCamera {
                NoteBox(text: "Camera recording was disabled for this recording.")
            } else {
                Toggle("Show camera", isOn: model.binding(\.style.camera.show, "cam-show"))
                Group {
                    Text("Position").font(.callout)
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow { corner(.topLeft); corner(.topRight) }
                        GridRow { corner(.bottomLeft); corner(.bottomRight) }
                    }
                    SliderRow(title: "Size", value: model.binding(\.style.camera.size, "cam-size"), range: 0.1...0.5, format: percent)
                    Picker("Shape", selection: model.binding(\.style.camera.shape, "cam-shape")) {
                        ForEach(CameraShape.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Shrink camera on zoom", isOn: model.binding(\.style.camera.shrinkOnZoom, "cam-shrink"))
                    Toggle("Mirror camera", isOn: model.binding(\.style.camera.flip, "cam-flip"))
                    Divider()
                    Button("Toggle Camera Fullscreen") { state.toggleCameraFullscreen() }
                    Text("Click on camera to toggle Full Screen at the playhead, or drag on the camera track.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!model.project.style.camera.show)
            }
        }
    }

    private func corner(_ c: Corner) -> some View {
        let on = model.project.style.camera.position == c
        return Button { model.update { $0.style.camera.position = c } } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                .frame(height: 34)
                .overlay(Text(c.title).font(.caption))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Keystrokes

struct KeystrokesPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.events.keystrokesCaptured {
                NoteBox(text: "Keystroke capture requires Accessibility permission. Enable it for future recordings.",
                        action: ("Open System Settings", { Permissions.openSettings(.accessibility) }))
            } else if model.events.keys.isEmpty {
                NoteBox(text: "No keystrokes were captured in this video.")
            }
            Toggle("Show Keystrokes", isOn: model.binding(\.style.keystrokes.show, "keys-show"))
            Group {
                SliderRow(title: "Size", value: model.binding(\.style.keystrokes.size, "keys-size"), range: 0.5...2.5,
                          format: { String(format: "%.1f×", $0) })
                Picker("Position", selection: model.binding(\.style.keystrokes.position, "keys-pos")) {
                    ForEach(KeystrokePosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Display", selection: model.binding(\.style.keystrokes.displayAll, "keys-all")) {
                    Text("Shortcuts only").tag(false)
                    Text("All keys").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            .disabled(!model.project.style.keystrokes.show)
        }
    }
}

// MARK: - Audio

struct AudioPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.hasAudio {
                NoteBox(text: "There is no audio in your video.")
            } else {
                Toggle("Mute all audio", isOn: model.binding(\.style.audio.muted, "audio-mute"))
                Group {
                    if model.project.recording.hasMicrophone {
                        SliderRow(title: model.project.recording.microphoneName ?? "Microphone",
                                  value: model.binding(\.style.audio.microphoneVolume, "audio-mic"), range: 0...2, format: percent)
                    }
                    if model.project.recording.hasSystemAudio {
                        SliderRow(title: "System audio", value: model.binding(\.style.audio.systemVolume, "audio-sys"), range: 0...2, format: percent)
                    }
                }
                .disabled(model.project.style.audio.muted)
            }
        }
    }
}
