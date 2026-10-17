import AppKit
import AVFoundation
import SwiftUI
import ShotcraftCore

/// Capture History overlay (CleanShot 5.0 `MediaHistoryOverlay`, ui-reference §10): a full-width strip of dark
/// glass across the middle of the active screen with filter pills and a horizontally scrolling row of captures.
/// It takes keyboard focus as a non-activating panel (the frontmost app stays active) and closes on Esc, on a
/// click in another app, or after Restore.
@MainActor
final class HistoryWindowController: NSObject {
    static let shared = HistoryWindowController()
    static let stripHeight: CGFloat = 280

    private var panel: OverlayPanel?
    private let model = HistoryStripModel()
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    var isShowing: Bool { panel?.isVisible ?? false }

    func show() {
        let screen = NSScreen.active
        let vis = screen.visibleFrame
        let frame = NSRect(x: screen.frame.minX, y: (vis.midY - Self.stripHeight / 2).rounded(),
                           width: screen.frame.width, height: Self.stripHeight)
        let p = panel ?? makePanel()
        panel = p
        model.prepareForShow()
        p.setFrame(frame, display: true)
        if !p.isVisible {
            p.alphaValue = 0
            p.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        } else {
            p.makeKeyAndOrderFront(nil)
        }
        installMonitors()
    }

    func close() {
        removeMonitors()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                // Re-opened while fading out: keep it.
                if self.keyMonitor == nil { p.orderOut(nil) }
            }
        })
    }

    /// Takes keyboard focus back (e.g. after Quick Look, opened from the strip, closes).
    func refocus() {
        guard let p = panel, p.isVisible, keyMonitor != nil else { return }
        p.makeKey()
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayWindow.makePanel(.zero, level: OverlayWindow.historyLevel, canBecomeKey: true)
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: HistoryStripView(store: HistoryStore.shared, model: model) { [weak self] in self?.close() })
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    // MARK: Keyboard / outside clicks

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                let code = Int(event.keyCode), flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                return MainActor.assumeIsolated { self.handleKey(code, flags) } ? nil : event
            }
        }
        if clickMonitor == nil {
            // Global monitors only see events going to other apps: a click anywhere else dismisses the strip.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        clickMonitor = nil
    }

    private func handleKey(_ code: Int, _ flags: NSEvent.ModifierFlags) -> Bool {
        switch code {
        case Keys.escape: close()
        case Keys.left: model.moveSelection(by: -1)
        case Keys.right: model.moveSelection(by: 1)
        case Keys.space: if let m = model.selected { QuickLookController.shared.toggle(m.url, pointSize: m.pointSize) }
        case Keys.returnKey, Keys.keypadEnter: if let m = model.selected { restore(m) }
        case Keys.c where flags == .command: if let m = model.selected { MediaActions.copy(m); HUD.show("Copied to clipboard") }
        case Keys.e where flags == .command: if let m = model.selected { annotate(m) }
        case Keys.delete where flags == .command: if let m = model.selected { MediaActions.moveToTrash(m) }
        case Keys.w where flags == .command: close()
        default: return false
        }
        return true
    }

    /// "Restore": puts the capture back into Quick Access.
    func restore(_ media: CapturedMedia) {
        guard FileManager.default.fileExists(atPath: media.url.path) else { NSSound.beep(); return }
        close()
        QuickAccessController.shared.show(media)
    }

    func annotate(_ media: CapturedMedia) {
        close()
        MediaActions.edit(media)
    }
}

/// Filter + selection state of the strip.
@MainActor
final class HistoryStripModel: ObservableObject {
    @Published var filter: HistoryIndex.Filter = .all { didSet { ensureSelection() } }
    @Published var selectedID: UUID?

    var visibleItems: [CapturedMedia] { HistoryStore.shared.items.filter { filter.matches($0.kind) } }
    var selected: CapturedMedia? { visibleItems.first { $0.id == selectedID } }

    func prepareForShow() {
        selectedID = nil
        ensureSelection()
    }

    func ensureSelection() {
        let items = visibleItems
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
    }

    func moveSelection(by delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[min(max(current + delta, 0), items.count - 1)].id
    }
}

// MARK: - Views

struct HistoryStripView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var model: HistoryStripModel
    let close: () -> Void
    @Default(.historyEnabled) private var enabled
    @Default(.historyRetentionDays) private var retentionDays

    private static let filters: [HistoryIndex.Filter] = [.all, .screenshots, .videos, .gifs]

    var body: some View {
        VStack(spacing: 18) {
            header
            if !enabled {
                emptyState("Capture History is disabled.", button: "Open Settings") { close(); Services.preferences?.show(pane: "advanced") }
            } else if model.visibleItems.isEmpty {
                emptyState("No files to restore...", button: nil, action: {})
            } else {
                row
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(StripBackground())
        .environment(\.colorScheme, .dark)
        .onChange(of: store.items.map(\.id)) { model.ensureSelection() }
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(Self.filters, id: \.self) { f in
                    Button { model.filter = f } label: {
                        Text(f.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(Capsule().fill(model.filter == f ? Color.accentColor : Color.white.opacity(0.15)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Menu {
                    Picker("Keep History", selection: $retentionDays) {
                        Text("1 day").tag(1)
                        Text("3 days").tag(3)
                        Text("1 week").tag(7)
                        Text("1 month").tag(30)
                        Text("Forever").tag(0)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Clear History...") { confirmClear() }.disabled(store.items.isEmpty)
                } label: {
                    // Same fixed 28 pt circle as Close: the label is the whole control, never stretched by the menu.
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("History settings")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 24)
        }
    }

    private var row: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(model.visibleItems, id: \.id) { media in
                        HistoryItemView(media: media, revision: store.revision(of: media),
                                        isSelected: model.selectedID == media.id) { model.selectedID = media.id }
                            .id(media.id)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 3)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func emptyState(_ title: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            if let button { Button(button, action: action).controlSize(.large) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func confirmClear() {
        if Alerts.confirm("Are you sure you want to delete all files from history?",
                          info: "Captures you haven't saved will be deleted. Saved files are kept.",
                          confirmTitle: "Clear History", destructive: true) {
            store.clear()
        }
    }
}

/// Dark blurred glass with hairline top/bottom borders.
private struct StripBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground()
            Color.black.opacity(0.3)
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                Spacer()
                Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            }
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct HistoryItemView: View {
    let media: CapturedMedia
    /// Changes whenever the media changes, so the thumbnail reloads (the reference-type `media` alone wouldn't).
    let revision: Int
    let isSelected: Bool
    let select: () -> Void
    @State private var thumbnail: NSImage?
    @State private var duration: String?

    private static let size = CGSize(width: 180, height: 120)

    var body: some View {
        VStack(spacing: 12) {
            thumbnailView
                .onTapGesture(count: 2) { HistoryWindowController.shared.annotate(media) }
                .onTapGesture { select() }
                .onDrag { NSItemProvider(contentsOf: media.url) ?? NSItemProvider() }
                .contextMenu { menuItems }
                .help("\(media.url.lastPathComponent) — \(media.createdAt.formatted(.relative(presentation: .named)))")
            if isSelected {
                Button { HistoryWindowController.shared.restore(media) } label: {
                    Label("Restore", systemImage: "return")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.accentColor))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Restore to Quick Access (Return)")
            } else {
                Color.clear.frame(height: 32)
            }
        }
        .task(id: "\(media.url.path)|\(revision)") { load() }
    }

    private var thumbnailView: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08))
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: Self.size.width, height: Self.size.height)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if media.isVideoLike {
                HStack(spacing: 4) {
                    Image(systemName: media.kind == .gif ? "photo.stack" : "video.fill")
                    if let duration { Text(duration).monospacedDigit() }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(8)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isSelected ? 3 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var menuItems: some View {
        Button("Restore") { HistoryWindowController.shared.restore(media) }
        Button(media.isImage ? "Open Annotation Tool…" : "Open Video Editor…") { HistoryWindowController.shared.annotate(media) }
        if media.isImage { Button("Pin to the Screen") { MediaActions.pin(media) } }
        Button("Quick Look") { QuickLookController.shared.toggle(media.url, pointSize: media.pointSize) }
        Divider()
        Button("Copy") { MediaActions.copy(media); HUD.show("Copied to clipboard") }
        Button("Save As…") { MediaActions.save(media, forceAsk: true) }
        Button("Upload to Cloud") { MediaActions.upload(media) }
        Button("Show in Finder") { MediaActions.showInFinder(media) }
        Divider()
        Button("Delete") { MediaActions.moveToTrash(media) }
    }

    private func load() {
        Thumbnailer.thumbnail(for: media.url, kind: media.kind, maxPixel: 480) { img in thumbnail = img }
        guard media.kind == .video || media.kind == .gif else { duration = nil; return }
        if media.kind == .gif { return }
        let asset = AVURLAsset(url: media.url)
        Task { @MainActor in
            if let d = try? await asset.load(.duration) { duration = OverlayFormat.duration(d.seconds) }
        }
    }
}
