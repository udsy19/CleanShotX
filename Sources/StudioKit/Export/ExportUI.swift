import AppKit
import SwiftUI
import ShotcraftCore

/// Export options sheet (FLExportPanel).
@MainActor
final class ExportPanelModel: ObservableObject {
    @Published var settings = ExportSettings()
    let base: CGSize
    let duration: Double
    let hasAudio: Bool
    /// "Export & Upload": the button reads "Export & Upload".
    let upload: Bool
    var onExport: (ExportSettings) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(base: CGSize, duration: Double, hasAudio: Bool, upload: Bool) {
        self.base = base; self.duration = duration; self.hasAudio = hasAudio; self.upload = upload
        var s = ExportSettings()
        s.format = ExportSettings.Format(rawValue: Defaults[.studioExportFormat]) ?? .h264
        let res = ExportSettings.Resolution(rawValue: Defaults[.studioExportResolution]) ?? .original
        s.resolution = ExportSettings.Resolution.options(for: base).contains(res) ? res : .original
        s.fps = Defaults[.studioExportFPS] == 30 ? 30 : 60
        s.quality = min(max(Defaults[.studioExportQuality], 0), 1)
        s.gifFPS = Defaults[.gifFPS]
        s.includeAudio = hasAudio
        settings = s
    }

    func persist() {
        Defaults[.studioExportFormat] = settings.format.rawValue
        Defaults[.studioExportResolution] = settings.resolution.rawValue
        Defaults[.studioExportFPS] = settings.fps
        Defaults[.studioExportQuality] = settings.quality
    }

    func title(for r: ExportSettings.Resolution) -> String {
        var s = settings; s.resolution = r
        let size = s.outputSize(base: base)
        return "\(r.title) (\(Int(size.width)) × \(Int(size.height)))"
    }

    var estimate: String {
        let bytes = EncoderEstimate.estimatedBytes(settings: settings, base: base, duration: duration, hasAudio: hasAudio)
        return "~" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ExportPanelView: View {
    @ObservedObject var model: ExportPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    label("Format")
                    Picker("", selection: $model.settings.format) {
                        ForEach(ExportSettings.Format.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Resolution")
                    Picker("", selection: $model.settings.resolution) {
                        ForEach(ExportSettings.Resolution.options(for: model.base), id: \.self) { Text(model.title(for: $0)).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Frame rate")
                    if model.settings.format == .gif {
                        Picker("", selection: $model.settings.gifFPS) {
                            ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        .labelsHidden()
                    } else {
                        Picker("", selection: $model.settings.fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                            .labelsHidden()
                    }
                }
                if model.settings.format != .gif {
                    GridRow {
                        label("Quality")
                        HStack(spacing: 8) {
                            Slider(value: $model.settings.quality, in: 0...1).controlSize(.small)
                            Text(ExportSettings.qualityTitle(model.settings.quality))
                                .foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }
                    }
                    GridRow {
                        label("Audio")
                        Toggle("", isOn: $model.settings.includeAudio)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(!model.hasAudio)
                            .help(model.hasAudio ? "Include the project's audio" : "This video has no audio.")
                    }
                }
            }
            Divider()
            HStack {
                Text("Estimated file size").foregroundStyle(.secondary)
                Spacer()
                Text(model.estimate).monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Cancel") { model.onCancel() }.keyboardShortcut(.cancelAction)
                Button(model.upload ? "Export & Upload" : "Export") { model.persist(); model.onExport(model.settings) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12))
        .padding(18)
        .frame(width: 340)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

// MARK: - Progress

@MainActor
final class RenderProgressModel: ObservableObject {
    @Published var progress = 0.0
    @Published var remaining = ""
    let started = Date()
    var onCancel: () -> Void = {}

    func update(_ p: Double) {
        progress = p
        let elapsed = Date().timeIntervalSince(started)
        guard p > 0.03, elapsed > 1 else { remaining = ""; return }
        let left = elapsed / p * (1 - p)
        remaining = left < 60 ? "~\(Int(left.rounded(.up)))s remaining" : "~\(TimeFormat.string(left, tenths: false)) remaining"
    }
}

struct RenderProgressView: View {
    @ObservedObject var model: RenderProgressModel
    var body: some View {
        VStack(spacing: 10) {
            Text("Exporting video...").font(.system(size: 13, weight: .semibold))
            ProgressView(value: model.progress).progressViewStyle(.linear).controlSize(.small)
            HStack {
                Text(model.remaining).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.progress * 100))%").foregroundStyle(.secondary)
            }
            .font(.system(size: 11).monospacedDigit())
            Button("Cancel Export") { model.onCancel() }.keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .frame(width: 320)
    }
}

/// Export progress in the Dock icon (FLDockProgressTracker).
@MainActor
enum DockProgress {
    private final class View: NSView {
        var progress = 0.0 { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            NSApp.applicationIconImage?.draw(in: bounds)
            let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: bounds.height * 0.1)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
            let fill = NSRect(x: bar.minX + 2, y: bar.minY + 2, width: max(0, (bar.width - 4) * CGFloat(progress)), height: bar.height - 4)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
        }
    }
    private static var sessions: [UUID: Double] = [:]
    private static var view: View?

    static func update(_ id: UUID, _ p: Double) {
        sessions[id] = p
        refresh()
    }

    static func end(_ id: UUID) {
        sessions[id] = nil
        refresh()
    }

    private static func refresh() {
        let tile = NSApp.dockTile
        guard !sessions.isEmpty else {
            tile.contentView = nil; view = nil; tile.badgeLabel = nil; tile.display(); return
        }
        if view == nil { view = View(frame: NSRect(origin: .zero, size: tile.size)); tile.contentView = view }
        view?.progress = sessions.values.reduce(0, +) / Double(sessions.count)
        tile.badgeLabel = sessions.count > 1 ? "\(sessions.count)" : nil
        tile.display()
    }
}
