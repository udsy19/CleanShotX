import AppKit
import ImageIO
import SwiftUI
import ShotcraftCore

struct WallpaperPane: View {
    @Default(.wallpaperSource) private var source
    @Default(.customWallpaperPath) private var customPath
    @Default(.wallpaperColor) private var color
    @Default(.updateWallpaperOnSpaceChange) private var updateOnSpaceChange
    @State private var iconsHidden = false

    var body: some View {
        PaneForm(pane: .wallpaper) {
            Section {
                WallpaperPreview(source: source, customPath: customPath, color: color)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                HelpText("This background replaces the desktop while desktop icons are hidden, and is used behind window screenshots set to “Desktop wallpaper”.")
            }

            Section("Background") {
                Picker("Source", selection: $source) {
                    Text("Desktop wallpaper").tag(WallpaperSource.desktop)
                    Text("Custom image").tag(WallpaperSource.custom)
                    Text("Plain color").tag(WallpaperSource.color)
                }
                .pickerStyle(.segmented)

                switch source {
                case .desktop:
                    Toggle("Update wallpaper when switching Spaces", isOn: $updateOnSpaceChange)
                case .custom:
                    LabeledContent("Image") {
                        HStack {
                            Text(customPath.isEmpty ? "No image chosen" : (customPath as NSString).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(customPath.isEmpty ? .secondary : .primary)
                                .help(customPath)
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
                    ColorPicker("Color", selection: $color.color, supportsOpacity: false)
                }
            }

            Section {
                LabeledContent {
                    Button(iconsHidden ? "Show Desktop Icons" : "Hide Desktop Icons") {
                        guard let capture = Services.capture else { return }
                        capture.setDesktopIconsHidden(!capture.desktopIconsHidden)
                        iconsHidden = capture.desktopIconsHidden
                    }
                    .disabled(Services.capture == nil)
                } label: {
                    Text("Desktop icons")
                    Text(iconsHidden ? "Icons are hidden behind the wallpaper." : "Hide icons for a clean desktop before presenting or recording.")
                }
            }
        }
        .onAppear { iconsHidden = Services.capture?.desktopIconsHidden ?? false }
    }
}

private struct WallpaperPreview: View {
    let source: WallpaperSource
    let customPath: String
    let color: RGBAColor
    @State private var image: NSImage?

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
        .task(id: "\(source.rawValue)|\(customPath)") { image = await Self.thumbnail(url: sourceURL) }
    }

    private var sourceURL: URL? {
        switch source {
        case .color: return nil
        case .custom: return customPath.isEmpty ? nil : URL(fileURLWithPath: customPath)
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
