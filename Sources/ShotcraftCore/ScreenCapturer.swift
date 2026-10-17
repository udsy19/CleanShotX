import AppKit
import ScreenCaptureKit

/// Still-image capture via ScreenCaptureKit (`SCScreenshotManager`, macOS 14+).
/// Our own windows (overlays, HUDs) are excluded unless `includeOwnWindows` is true.
public enum ScreenCapturer {
    public enum CaptureError: LocalizedError {
        case noDisplay, noWindow, failed
        public var errorDescription: String? {
            switch self {
            case .noDisplay: "Screen display error"
            case .noWindow: "The selected window is no longer available."
            case .failed: "Screen content error"
            }
        }
    }

    public static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Captures `cocoaRect` (global Cocoa coords) from the display of `screen`, at the display's backing scale.
    public static func capture(rect cocoaRect: CGRect, on screen: NSScreen, showsCursor: Bool = Defaults[.showCursorOnScreenshots],
                               includeOwnWindows: Bool = false) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.noDisplay }
        let excluded = includeOwnWindows ? [] : content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let local = ScreenGeometry.displayLocalRect(cocoaRect.intersection(screen.frame), on: screen)
        let scale = screen.backingScaleFactor
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures an entire display.
    public static func capture(screen: NSScreen, showsCursor: Bool = Defaults[.showCursorOnScreenshots],
                               includeOwnWindows: Bool = false) async throws -> CGImage {
        try await capture(rect: screen.frame, on: screen, showsCursor: showsCursor, includeOwnWindows: includeOwnWindows)
    }

    /// Captures a single window (desktop-independent), optionally with its drop shadow.
    public static func capture(windowID: CGWindowID, shadow: Bool = Defaults[.captureWindowShadow]) async throws -> (CGImage, CGFloat) {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.ignoreShadowsSingleWindow = !shadow
        config.shouldBeOpaque = false
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Captures a rect that may span several displays, stitched at the highest backing scale.
    @MainActor
    public static func capture(globalRect cocoaRect: CGRect, showsCursor: Bool = Defaults[.showCursorOnScreenshots]) async throws -> (CGImage, CGFloat) {
        let screens = NSScreen.screens.filter { $0.frame.intersects(cocoaRect) }
        guard !screens.isEmpty else { throw CaptureError.noDisplay }
        if screens.count == 1 {
            let s = screens[0]
            return (try await capture(rect: cocoaRect, on: s, showsCursor: showsCursor), s.backingScaleFactor)
        }
        let scale = screens.map(\.backingScaleFactor).max() ?? 2
        let w = Int((cocoaRect.width * scale).rounded()), h = Int((cocoaRect.height * scale).rounded())
        guard let ctx = ImageTools.context(width: w, height: h) else { throw CaptureError.failed }
        for s in screens {
            let part = cocoaRect.intersection(s.frame)
            let img = try await capture(rect: part, on: s, showsCursor: showsCursor)
            let dest = CGRect(x: (part.minX - cocoaRect.minX) * scale, y: (part.minY - cocoaRect.minY) * scale,
                              width: part.width * scale, height: part.height * scale)
            ctx.draw(img, in: dest)
        }
        guard let out = ctx.makeImage() else { throw CaptureError.failed }
        return (out, scale)
    }
}

/// Lightweight on-screen window list (CoreGraphics), used for window snapping/hover highlighting.
public struct WindowInfo: Sendable {
    public let id: CGWindowID
    /// CG global coordinates (top-left origin).
    public let cgFrame: CGRect
    public let ownerName: String
    public let ownerPID: pid_t
    public let title: String
    public let layer: Int
    public var cocoaFrame: CGRect { ScreenGeometry.cocoaRect(fromCG: cgFrame) }

    /// Normal-layer, on-screen windows front-to-back, excluding our own process.
    public static func onScreen(includeOwn: Bool = false) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = d[kCGWindowLayer as String] as? Int else { return nil }
            if !includeOwn && pid == me { return nil }
            let alpha = d[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01 else { return nil }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard frame.width > 20, frame.height > 20 else { return nil }
            return WindowInfo(id: id, cgFrame: frame, ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                              ownerPID: pid, title: d[kCGWindowName as String] as? String ?? "", layer: layer)
        }
    }
}
