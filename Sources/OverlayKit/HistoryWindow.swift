import AppKit
import SwiftUI
import ShotcraftCore

/// Capture History window (CleanShot's `MediaHistoryOverlay`).
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    func show() {
        let w = window ?? makeWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Capture History"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 340)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: HistoryView(store: HistoryStore.shared))
        if !w.setFrameUsingName("ShotcraftCaptureHistory") { w.center() }
        w.setFrameAutosaveName("ShotcraftCaptureHistory")
        return w
    }
}

// MARK: - Views

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @Default(.historyEnabled) private var enabled
    @Default(.historyRetentionDays) private var retentionDays
    @State private var filter: HistoryIndex.Filter = .all

    private var filtered: [CapturedMedia] { store.items.filter { filter.matches($0.kind) } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !enabled {
                disabledState
            } else if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)], spacing: 14) {
                        ForEach(filtered, id: \.id) { media in
                            HistoryItemView(media: media)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 340)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $filter) {
                ForEach(HistoryIndex.Filter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!enabled)
            Spacer()
            Menu {
                Picker("Keep captures for", selection: $retentionDays) {
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("1 week").tag(7)
                    Text("1 month").tag(30)
                    Text("Forever").tag(0)
                }
                .pickerStyle(.inline)
                Divider()
                Button("Clear History…") { confirmClear() }
                    .disabled(store.items.isEmpty)
                Button("Capture History Settings…") { Services.preferences?.show(pane: "advanced") }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("History settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)      // below the transparent title bar
        .padding(.bottom, 10)
    }

    private var disabledState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.badge.xmark").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("Capture History is disabled.").font(.title3.weight(.semibold))
            Text("Turn it on to keep your recent screenshots and recordings here.")
                .foregroundStyle(.secondary)
            Button("Open Settings") { Services.preferences?.show(pane: "advanced") }
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(store.items.isEmpty ? "No captures yet" : "No \(filter.title.lowercased()) yet")
                .font(.title3.weight(.semibold))
            Text("Your captures from the last \(retentionDescription) appear here.").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var retentionDescription: String {
        switch retentionDays {
        case 0: "while history is enabled"
        case 1: "day"
        case 7: "week"
        case 30: "month"
        default: "\(retentionDays) days"
        }
    }

    private func confirmClear() {
        if Alerts.confirm("Are you sure you want to delete all files from history?",
                          info: "Captures you haven't saved will be deleted. Saved files are kept.",
                          confirmTitle: "Clear History", destructive: true) {
            store.clear()
        }
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
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct HistoryItemView: View {
    let media: CapturedMedia
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var thumbKey: String {
        let mtime = (try? media.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(media.url.path)|\(mtime)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else {
                    ProgressView().controlSize(.small)
                }
                if media.isVideoLike {
                    VStack { Spacer(); HStack {
                        Label(media.kind == .gif ? "GIF" : "Video", systemImage: media.kind == .gif ? "photo.stack" : "video.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                        Spacer()
                    } }
                    .padding(6)
                }
                if hovering { hoverActions }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(hovering ? 0.25 : 0.08)))
            HStack {
                Text(media.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Text(OverlayFormat.dimensions(media.pixelSize)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { QuickAccessController.shared.show(media) }
        .onDrag { NSItemProvider(contentsOf: media.url) ?? NSItemProvider() }
        .contextMenu { menuItems }
        .task(id: thumbKey) { loadThumbnail() }
        .help(media.url.lastPathComponent)
    }

    private var hoverActions: some View {
        ZStack {
            Color.black.opacity(0.35)
            HStack(spacing: 8) {
                actionButton("rectangle.portrait.on.rectangle.portrait", "Open in Quick Access") { QuickAccessController.shared.show(media) }
                actionButton("doc.on.doc", "Copy") { copy() }
                actionButton(media.isImage ? "pencil" : "scissors", media.isImage ? "Annotate" : "Open Video Editor") { MediaActions.edit(media) }
                if media.isImage { actionButton("pin", "Pin to the Screen") { MediaActions.pin(media) } }
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
            }
        }
    }

    private func actionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private var menuItems: some View {
        Button("Open in Quick Access") { QuickAccessController.shared.show(media) }
        Button(media.isImage ? "Annotate" : "Open Video Editor") { MediaActions.edit(media) }
        Button("Copy") { copy() }
        if media.isImage { Button("Pin to the Screen") { MediaActions.pin(media) } }
        Button("Upload") { upload() }
        Divider()
        Button("Open") { MediaActions.open(media) }
        Button("Show in Finder") { MediaActions.showInFinder(media) }
        Button("Save As…") { MediaActions.save(media, forceAsk: true) }
        Divider()
        Button("Move to Trash") { MediaActions.moveToTrash(media) }
    }

    private func copy() {
        MediaActions.copy(media)
        HUD.show("Copied to clipboard")
    }

    private func upload() {
        MediaActions.upload(media, progress: nil, completion: { result in
            switch result {
            case .success: HUD.show("Link has been copied", symbol: "link")
            case .failure(let error):
                if case UploadError.notConfigured = error { return }
                Alerts.error("Upload failed.", error)
            }
        })
    }

    private func loadThumbnail() {
        Thumbnailer.thumbnail(for: media.url, kind: media.kind, maxPixel: 480) { img in
            thumbnail = img
        }
    }
}
