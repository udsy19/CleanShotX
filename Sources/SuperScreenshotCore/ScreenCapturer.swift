import AppKit
import ScreenCaptureKit

/// Which of Super Screenshot's own windows stay out of captures. Like CleanShot, screenshots include pinned
/// screenshots, editor and settings windows (they are part of the user's screen), but never our transient UI:
/// anything above the floating window level (selection overlays, Quick Access cards, HUDs, alerts) plus windows a
/// module explicitly flags with `exclude(_:)`. Recordings use the same rule.
public enum CaptureExclusion {
    @MainActor private static let flagged = NSHashTable<NSWindow>.weakObjects()

    /// Keep `window` out of every capture (e.g. a floating-level control panel).
    @MainActor public static func exclude(_ window: NSWindow) { flagged.add(window) }

    @MainActor public static var flaggedWindowIDs: Set<CGWindowID> {
        Set(flagged.allObjects.map { CGWindowID($0.windowNumber) })
    }

    /// Own-app windows to exclude from `content`, except those listed in `keeping`.
    public static func excludedWindows(in content: SCShareableContent, flagged: Set<CGWindowID>,
                                       keeping: Set<CGWindowID> = []) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        return content.windows.filter { w in
            w.owningApplication?.processID == pid && !keeping.contains(w.windowID)
                && (w.windowLayer > floating || flagged.contains(w.windowID))
        }
    }
}

/// Runs `operation`, giving up with `CaptureError.timedOut` after `seconds`. The caller is released on time even
/// when the operation ignores cancellation (ScreenCaptureKit calls do): it keeps running detached until it
/// finishes on its own, and its late result is dropped.
public func withTimeout<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let gate = ContinuationGate(cont)
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if !Task.isCancelled { gate.resume(.failure(ScreenCapturer.CaptureError.timedOut)) }
        }
        Task {
            let result: Result<T, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            timer.cancel()
            gate.resume(result)
        }
    }
}

/// Resumes a continuation at most once, whichever side (result or timeout) gets there first.
private final class ContinuationGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// Still-image capture via ScreenCaptureKit (`SCScreenshotManager`, macOS 14+), honoring `CaptureExclusion`.
public enum ScreenCapturer {
    public enum CaptureError: LocalizedError, Equatable {
        case noDisplay, noWindow, failed
        /// Screen Recording permission is missing (or macOS still thinks so: the permission cache goes stale
        /// when it is toggled while the app runs).
        case permissionDenied
        /// The system returned an image with nothing in it; same cause as `permissionDenied` in practice.
        case blank
        case timedOut
        public var errorDescription: String? {
            switch self {
            case .noDisplay: "Screen display error"
            case .noWindow: "The selected window is no longer available."
            case .failed: "Screen content error"
            case .permissionDenied: "Super Screenshot doesn't have permission to record the screen."
            case .blank: "The screen couldn't be read. If you recently changed the Screen Recording permission, quit and reopen Super Screenshot."
            case .timedOut: "The screen didn't respond in time. Please try again."
            }
        }
        /// Fixed in System Settings → Privacy & Security → Screen & System Audio Recording.
        public var isPermissionProblem: Bool { self == .permissionDenied || self == .blank }
    }

    /// Default patience for one ScreenCaptureKit call before the UI is torn down with a message.
    public static let timeout: TimeInterval = 10

    public static func shareableContent() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw classified(error) }
    }

    /// ScreenCaptureKit's permission failures become `CaptureError.permissionDenied`; everything else passes through.
    public static func classified(_ error: Error) -> Error {
        if let e = error as? CaptureError { return e }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue { return CaptureError.permissionDenied }
        if !CGPreflightScreenCaptureAccess() { return CaptureError.permissionDenied }
        return error
    }

    /// One screenshot through `SCScreenshotManager`, with a clear error when the system hands back nothing.
    private static func screenshot(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> CGImage {
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch { throw classified(error) }
        guard image.width > 0, image.height > 0, !ImageTools.isFullyTransparent(image) else { throw CaptureError.blank }
        return image
    }

    /// Captures `cocoaRect` (global Cocoa coords) from the display of `screen`, at the display's backing scale.
    public static func capture(rect cocoaRect: CGRect, on screen: NSScreen,
                               showsCursor: Bool = Defaults[.showCursorOnScreenshots]) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.noDisplay }
        let flagged = await MainActor.run { CaptureExclusion.flaggedWindowIDs }
        let filter = SCContentFilter(display: display, excludingWindows: CaptureExclusion.excludedWindows(in: content, flagged: flagged))
        let config = SCStreamConfiguration()
        let local = ScreenGeometry.displayLocalRect(cocoaRect.intersection(screen.frame), on: screen)
        let scale = screen.backingScaleFactor
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        try ImageTools.validateSize(width: config.width, height: config.height)
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        return try await screenshot(filter, config)
    }

    /// Captures an entire display.
    public static func capture(screen: NSScreen, showsCursor: Bool = Defaults[.showCursorOnScreenshots]) async throws -> CGImage {
        try await capture(rect: screen.frame, on: screen, showsCursor: showsCursor)
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
        try ImageTools.validateSize(width: config.width, height: config.height)
        config.ignoreShadowsSingleWindow = !shadow
        config.shouldBeOpaque = false
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await screenshot(filter, config)
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
        let ctx = try ImageTools.checkedContext(width: w, height: h)
        for s in screens {
            let part = cocoaRect.intersection(s.frame)
            let img = try await capture(rect: part, on: s, showsCursor: showsCursor)
            let dest = CGRect(x: (part.minX - cocoaRect.minX) * scale, y: (part.minY - cocoaRect.minY) * scale,
                              width: part.width * scale, height: part.height * scale)
            ctx.draw(img, in: dest)
        }
        guard let out = ctx.makeImage() else { throw ImageError.outOfMemory(width: w, height: h) }
        return (out, scale)
    }

    /// Explains a failed capture. Permission problems get the "Open System Settings" alert; anything else an
    /// error alert titled `message`. Nothing is written to disk by any caller on these paths.
    @MainActor
    public static func report(_ error: Error, _ message: String) {
        if let e = classified(error) as? CaptureError, e.isPermissionProblem {
            Log.capture.error("Capture failed: \(e.localizedDescription, privacy: .public)")
            Permissions.explainScreenRecordingProblem(e.localizedDescription)
        } else {
            Alerts.error(message, error)
        }
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

    /// On-screen windows front-to-back. Our own windows are included only when they are capturable per
    /// `CaptureExclusion` (pins, editors), so window selection matches what a screenshot would show.
    @MainActor
    public static func onScreen() -> [WindowInfo] {
        let flagged = CaptureExclusion.flaggedWindowIDs
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = d[kCGWindowLayer as String] as? Int else { return nil }
            if pid == me && (layer > floating || flagged.contains(id)) { return nil }
            let alpha = d[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01 else { return nil }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard frame.width > 20, frame.height > 20 else { return nil }
            return WindowInfo(id: id, cgFrame: frame, ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                              ownerPID: pid, title: d[kCGWindowName as String] as? String ?? "", layer: layer)
        }
    }
}
