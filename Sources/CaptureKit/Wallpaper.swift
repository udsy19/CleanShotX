import AppKit
import ScreenCaptureKit
import ShotcraftCore

/// Wallpaper images for the desktop-icon covers and window-screenshot backgrounds.
@MainActor
enum WallpaperProvider {

    /// What the desktop of `screen` looks like right now, without icons, at the screen's pixel size: a
    /// ScreenCaptureKit grab of the system's wallpaper window(s), so dynamic, aerial and system landscape
    /// wallpapers match pixel for pixel. Falls back to rendering `desktopImageURL` (honoring the user's
    /// fill / fit / stretch / center choice) only when the grab fails.
    static func renderedDesktop(for screen: NSScreen) async -> CGImage? {
        if let live = await grabWallpaperWindows(for: screen) { return live }
        return renderDesktopPicture(for: screen)
    }

    /// Content of a "Hide desktop icons" cover per the Wallpaper settings; nil = no cover for this screen
    /// (better to leave the icons visible than to show a desktop that is not the user's).
    static func iconCover(for screen: NSScreen) async -> IconCoverContent? {
        switch Defaults[.wallpaperSource] {
        case .color:
            return .color(Defaults[.wallpaperColor])
        case .custom:
            if let src = customImage() {
                return render(src, canvas: pixelSize(of: screen), mode: .fill, background: .black, centerScale: 1).map(IconCoverContent.image)
            }
            return await renderedDesktop(for: screen).map(IconCoverContent.image)
        case .desktop:
            return await renderedDesktop(for: screen).map(IconCoverContent.image)
        }
    }

    static func customImage() -> CGImage? {
        let path = (Defaults[.customWallpaperPath] as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        return loadImage(URL(fileURLWithPath: path))
    }

    // MARK: Helpers

    static func pixelSize(of screen: NSScreen) -> CGSize {
        CGSize(width: (screen.frame.width * screen.backingScaleFactor).rounded(),
               height: (screen.frame.height * screen.backingScaleFactor).rounded())
    }

    static func loadImage(_ url: URL) -> CGImage? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        if let img = ImageTools.load(url) { return img }
        return NSImage(contentsOf: url)?.cgImage
    }

    /// Draws `image` into a new bitmap of `canvas` pixels. `centerScale` converts image pixels to canvas pixels
    /// for `.center` placement.
    static func render(_ image: CGImage, canvas: CGSize, mode: SelectionGeometry.ImagePlacement,
                       background: RGBAColor, centerScale: CGFloat) -> CGImage? {
        let w = Int(canvas.width), h = Int(canvas.height)
        guard w > 0, h > 0, let ctx = ImageTools.context(width: w, height: h) else { return nil }
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        var imgSize = CGSize(width: image.width, height: image.height)
        if mode == .center { imgSize = CGSize(width: imgSize.width * centerScale, height: imgSize.height * centerScale) }
        ctx.draw(image, in: SelectionGeometry.placement(of: imgSize, in: canvas, mode: mode))
        return ctx.makeImage()
    }

    /// Renders the file behind `desktopImageURL` (may be a still of a dynamic set, so only a fallback).
    private static func renderDesktopPicture(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let src = loadImage(url) else { return nil }
        let opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (opts[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
            ?? .scaleProportionallyUpOrDown
        let clipping = (opts[.allowClipping] as? NSNumber)?.boolValue ?? true
        let fill = (opts[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
        let mode: SelectionGeometry.ImagePlacement
        switch scaling {
        case .scaleAxesIndependently: mode = .stretch
        case .scaleNone: mode = .center
        default: mode = clipping ? .fill : .fit
        }
        let bg = fill.map { RGBAColor(r: $0.redComponent, g: $0.greenComponent, b: $0.blueComponent) } ?? .black
        // `.center` draws at the image's point size (honoring its DPI), converted to screen pixels.
        var factor = screen.backingScaleFactor
        if mode == .center, let pts = NSImage(contentsOf: url)?.size, pts.width > 0 {
            factor *= pts.width / CGFloat(src.width)
        }
        return render(src, canvas: pixelSize(of: screen), mode: mode, background: bg, centerScale: factor)
    }

    /// True for the system's wallpaper windows: owned by the Dock or the Wallpaper agent, at or below the
    /// desktop level (under the icons), excluding the full-screen backdrop that sits just above it.
    nonisolated static func isWallpaperWindow(owner bundleID: String?, ownerName: String?, layer: Int) -> Bool {
        let wallpaperOwner = bundleID == "com.apple.dock" || bundleID?.hasPrefix("com.apple.wallpaper") == true
            || ownerName == "Wallpaper"
        return wallpaperOwner && layer <= Int(CGWindowLevelForKey(.desktopWindow))
    }

    /// ScreenCaptureKit grab of the wallpaper window(s) on `screen` only (icons, our covers and every other
    /// window left out), at the display's backing scale. Needs screen-recording access.
    private static func grabWallpaperWindows(for screen: NSScreen) async -> CGImage? {
        guard Permissions.hasScreenRecording,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
        let cgScreen = ScreenGeometry.cgRect(fromCocoa: screen.frame)
        let windows = content.windows.filter {
            isWallpaperWindow(owner: $0.owningApplication?.bundleIdentifier, ownerName: $0.owningApplication?.applicationName,
                              layer: $0.windowLayer) && $0.frame.intersects(cgScreen)
        }
        guard !windows.isEmpty else { return nil }
        let filter = SCContentFilter(display: display, including: windows)
        let config = SCStreamConfiguration()
        let pixel = pixelSize(of: screen)
        config.width = Int(pixel.width)
        config.height = Int(pixel.height)
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// What a desktop-icon cover shows.
enum IconCoverContent {
    case image(CGImage)
    case color(RGBAColor)
}

/// Places a window screenshot onto the configured background ("Window background" settings).
@MainActor
enum WindowBackgroundComposer {

    /// - Parameters:
    ///   - image: the window capture (with or without the system shadow).
    ///   - scale: its backing scale; padding is in points.
    ///   - style: effective background style (Shift already applied).
    ///   - screen: the screen the window is on (for the desktop wallpaper).
    static func compose(_ image: CGImage, scale: CGFloat, style: WindowBackgroundStyle, screen: NSScreen,
                        hasSystemShadow: Bool) async -> CGImage {
        guard style != .transparent else { return image }
        let pad = CGFloat(max(0, Defaults[.windowBackgroundPadding])) * scale
        let w = CGFloat(image.width) + pad * 2, h = CGFloat(image.height) + pad * 2
        guard let ctx = ImageTools.context(width: Int(w.rounded()), height: Int(h.rounded())) else { return image }
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)

        var wallpaper: CGImage?
        switch style {
        case .desktopWallpaper: wallpaper = await WallpaperProvider.renderedDesktop(for: screen)
        case .customWallpaper: wallpaper = WallpaperProvider.customImage()
            if wallpaper == nil { wallpaper = await WallpaperProvider.renderedDesktop(for: screen) }
        case .color, .transparent: break
        }
        if let wallpaper {
            ctx.interpolationQuality = .high
            ctx.draw(wallpaper, in: SelectionGeometry.placement(of: CGSize(width: wallpaper.width, height: wallpaper.height),
                                                                in: canvas.size, mode: .fill))
        } else {
            ctx.setFillColor(Defaults[.windowBackgroundColor].cgColor)
            ctx.fill(canvas)
        }

        let dest = CGRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height))
        ctx.saveGState()
        if !hasSystemShadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 28 * scale,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4))
        }
        ctx.draw(image, in: dest)
        ctx.restoreGState()
        return ctx.makeImage() ?? image
    }

    /// Shift held at capture time flips between "transparent" and the configured background
    /// (or the desktop wallpaper when the preference is transparent).
    static func effectiveStyle(preference: WindowBackgroundStyle, shiftHeld: Bool) -> WindowBackgroundStyle {
        guard shiftHeld else { return preference }
        return preference == .transparent ? .desktopWallpaper : .transparent
    }
}
