import AppKit
import ImageIO
import SwiftUI
import ShotcraftCore

struct WallpaperPane: View {
    @Default(.wallpaperSource) private var source
    @Default(.customWallpaperPath) private var customPath
    @Default(.wallpaperColor) private var color
    @Default(.updateWallpaperOnSpaceChange) private var updateOnSpaceChange
    @StateObject private var icons = DesktopIconsModel()

    var body: some View {
        PaneForm(pane: .wallpaper) {
            Section {
                WallpaperPreview(source: source, customPath: customPath, color: color)
                    .frame(maxWidth: .infinity)
                Picker(selection: sourceBinding) {
                    Text("Desktop wallpaper").tag(WallpaperSource.desktop)
                    Text("Custom image").tag(WallpaperSource.custom)
                    Text("Plain color").tag(WallpaperSource.color)
                } label: {
                    Text("Wallpaper")
                    Text("Set a custom wallpaper used to hide desktop icons and as the background behind window screenshots.")
                }

                switch source {
                case .desktop:
                    SettingToggle("Update wallpaper when switching Spaces", isOn: $updateOnSpaceChange)
                case .custom:
                    LabeledContent("Image") {
                        HStack {
                            Text(customPath.isEmpty ? "No image chosen" : (customPath as NSString).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(customImageMissing ? .red : customPath.isEmpty ? .secondary : .primary)
                                .help(customImageMissing ? "The file no longer exists: \(customPath)" : customPath)
                            Button("Choose…") {
                                if let url = Panels.chooseImage(title: "Choose Wallpaper") { customPath = url.path }
                            }
                            if !customPath.isEmpty {
                                Button { Panels.reveal(path: customPath) } label: { Image(systemName: "arrow.right.circle") }
                                    .buttonStyle(.borderless).help("Show in Finder")
                            }
                        }
                    }
                case .color:
                    ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                }
            } header: { Text("Desktop") }

            Section {
                LabeledContent {
                    Button(icons.hidden ? "Show Desktop Icons" : "Hide Desktop Icons") { icons.toggle() }
                        .disabled(!icons.available)
                } label: {
                    Text("Desktop icons")
                    Text(icons.hidden ? "Icons are hidden behind the wallpaper." : "Hide icons for a clean desktop before presenting or recording.")
                }
            }
        }
    }

    private var customImageMissing: Bool {
        !customPath.isEmpty && !FileManager.default.fileExists(atPath: (customPath as NSString).expandingTildeInPath)
    }

    /// Window screenshots set to "With wallpaper" follow the wallpaper chosen here.
    private var sourceBinding: Binding<WallpaperSource> {
        Binding(get: { source }, set: { source = $0; WindowBackgroundMapping.syncAfterWallpaperChange() })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { color.swiftUIColor }, set: {
            color = RGBAColor($0)
            WindowBackgroundMapping.syncAfterWallpaperChange()
        })
    }
}

/// Mirrors `Services.capture.desktopIconsHidden`, which can also change from the menu bar, a shortcut or the URL
/// scheme while Settings is open; re-read on activation and periodically while visible.
@MainActor
private final class DesktopIconsModel: ObservableObject {
    @Published private(set) var hidden = false
    private var timer: Timer?
    private var activation: NSObjectProtocol?

    var available: Bool { Services.capture != nil }

    init() {
        refresh()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
        timer?.invalidate()
    }

    func refresh() {
        let now = Services.capture?.desktopIconsHidden ?? false
        if now != hidden { hidden = now }
    }

    func toggle() {
        guard let capture = Services.capture else { return }
        capture.setDesktopIconsHidden(!capture.desktopIconsHidden)
        refresh()
    }
}

private struct WallpaperPreview: View {
    let source: WallpaperSource
    let customPath: String
    let color: RGBAColor
    @State private var image: NSImage?
    /// Bumped when the desktop picture may have changed (Space switch, app activation).
    @State private var desktopRevision = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(color.swiftUIColor)
            if let image, source != .color {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 240, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 3, y: 1)
        .padding(.vertical, 4)
        .accessibilityLabel("Wallpaper preview")
        .task(id: "\(source.rawValue)|\(customPath)|\(desktopRevision)") { image = await Self.thumbnail(url: sourceURL) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            if source == .desktop { desktopRevision += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if source == .desktop { desktopRevision += 1 }
        }
    }

    private var sourceURL: URL? {
        switch source {
        case .color: return nil
        case .custom: return customPath.isEmpty ? nil : URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
        case .desktop: return NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        }
    }

    /// Downsampled off the main thread — wallpapers are often 5K+ HEICs.
    private static func thumbnail(url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 720,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        return cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}
