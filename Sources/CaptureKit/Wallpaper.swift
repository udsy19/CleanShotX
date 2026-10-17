import AppKit
import ScreenCaptureKit
import ShotcraftCore

/// Wallpaper images for the desktop-icon covers and window-screenshot backgrounds.
@MainActor
enum WallpaperProvider {

    /// The desktop picture of `screen`, rendered at the screen's pixel size honoring the user's
    /// "fill / fit / stretch / center" choice. Falls back to grabbing the Dock's wallpaper window (dynamic
    /// wallpapers that NSImage cannot decode), then nil.
    static func renderedDesktop(for screen: NSScreen) async -> CGImage? {
        let pixel = pixelSize(of: screen)
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let src = loadImage(url) {
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
            return render(src, canvas: pixel, mode: mode, background: bg, centerScale: factor)
        }
        return await grabWallpaperWindow(for: screen)
    }

    /// Image for the "Hide desktop icons" covers, per the Wallpaper settings. nil = use `wallpaperColor`.
    static func iconCoverImage(for screen: NSScreen) async -> CGImage? {
        switch Defaults[.wallpaperSource] {
        case .color: return nil
        case .custom:
            guard let src = customImage() else { return await renderedDesktop(for: screen) }
            return render(src, canvas: pixelSize(of: screen), mode: .fill, background: .black, centerScale: 1)
        case .desktop:
            return await renderedDesktop(for: screen)
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

    /// ScreenCaptureKit grab of the Dock-owned wallpaper window covering `screen` (needs screen-recording access).
    private static func grabWallpaperWindow(for screen: NSScreen) async -> CGImage? {
        guard Permissions.hasScreenRecording else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        let cgScreen = ScreenGeometry.cgRect(fromCocoa: screen.frame)
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.dock" && $0.windowLayer <= desktopLevel + 1
                && $0.frame.intersects(cgScreen)
        }
        guard let window = candidates.max(by: { $0.frame.intersection(cgScreen).width * $0.frame.intersection(cgScreen).height
                                                < $1.frame.intersection(cgScreen).width * $1.frame.intersection(cgScreen).height }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return render(img, canvas: pixelSize(of: screen), mode: .fill, background: .black, centerScale: 1)
    }
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
