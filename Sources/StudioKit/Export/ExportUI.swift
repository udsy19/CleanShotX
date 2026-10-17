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
    let audioMuted: Bool
    var onExport: (ExportSettings) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(base: CGSize, duration: Double, hasAudio: Bool, audioMuted: Bool) {
        self.base = base; self.duration = duration; self.hasAudio = hasAudio; self.audioMuted = audioMuted
        var s = ExportSettings()
        s.format = ExportSettings.Format(rawValue: Defaults[.studioExportFormat]) ?? .h264
        s.resolution = ExportSettings.Resolution(rawValue: Defaults[.studioExportResolution]) ?? .original
        s.fps = Defaults[.studioExportFPS] == 30 ? 30 : 60
        s.quality = Defaults[.studioExportQuality]
        s.optimizedForSharing = Defaults[.studioExportOptimized]
        s.gifFPS = Defaults[.gifFPS]
        s.includeAudio = hasAudio && !audioMuted
        settings = s
    }

    func persist() {
        Defaults[.studioExportFormat] = settings.format.rawValue
        Defaults[.studioExportResolution] = settings.resolution.rawValue
        Defaults[.studioExportFPS] = settings.fps
        Defaults[.studioExportQuality] = settings.quality
        Defaults[.studioExportOptimized] = settings.optimizedForSharing
    }

    var outputSize: CGSize { settings.outputSize(base: base) }
    var estimate: String {
        let bytes = EncoderEstimate.estimatedBytes(settings: settings, base: base, duration: duration, hasAudio: hasAudio && !audioMuted)
        return "~" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ExportPanelView: View {
    @ObservedObject var model: ExportPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title3.weight(.semibold))
            Form {
                Picker("Format", selection: $model.settings.format) {
                    ForEach(ExportSettings.Format.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Resolution", selection: $model.settings.resolution) {
                    ForEach(ExportSettings.Resolution.allCases, id: \.self) { r in
                        Text(r == .original ? "Original (\(Int(model.base.width))×\(Int(model.base.height)))" : r.title).tag(r)
                    }
                }
                if model.settings.format == .gif {
                    Picker("Frame rate", selection: $model.settings.gifFPS) {
                        ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                } else {
                    Picker("Frame rate", selection: $model.settings.fps) {
                        Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }
                    .disabled(model.settings.optimizedForSharing)
                    LabeledContent("Quality") {
                        Slider(value: $model.settings.quality, in: 0...1) { EmptyView() } minimumValueLabel: {
                            Text("Smaller").font(.caption)
                        } maximumValueLabel: { Text("Better").font(.caption) }
                        .disabled(model.settings.optimizedForSharing)
                    }
                    Toggle("Optimized for sharing", isOn: $model.settings.optimizedForSharing)
                        .help("Balances quality and loading time: H.264, up to 1080p and 30 fps.")
                    Toggle("Include audio", isOn: $model.settings.includeAudio)
                        .disabled(!model.hasAudio || model.audioMuted)
                    if !model.hasAudio {
                        Text("There is no audio in your video.").font(.caption).foregroundStyle(.secondary)
                    } else if model.audioMuted {
                        Text("Audio is muted in your project.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Output size") { Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))").monospacedDigit() }
                LabeledContent("Estimated file size") { Text(model.estimate).monospacedDigit() }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { model.onCancel() }.keyboardShortcut(.cancelAction)
                Button("Export") { model.persist(); model.onExport(model.settings) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

// MARK: - Progress

@MainActor
final class RenderProgressModel: ObservableObject {
    @Published var progress = 0.0
    @Published var detail = "Preparing…"
    let started = Date()
    var onCancel: () -> Void = {}

    func update(_ p: Double) {
        progress = p
        let elapsed = Date().timeIntervalSince(started)
        if p > 0.03 {
            let remaining = elapsed / p * (1 - p)
            detail = "\(Int(p * 100))% — about \(TimeFormat.string(remaining, tenths: false)) remaining"
        } else {
            detail = "\(Int(p * 100))%"
        }
    }
}

struct RenderProgressView: View {
    @ObservedObject var model: RenderProgressModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exporting video").font(.headline)
            ProgressView(value: model.progress).progressViewStyle(.linear)
            HStack {
                Text(model.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Cancel Processing…") { model.onCancel() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 380)
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
