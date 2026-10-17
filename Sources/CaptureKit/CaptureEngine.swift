import AppKit
import ScreenCaptureKit
import ShotcraftCore

/// The screen showing the largest part of `rect` (the active screen when it is off-screen).
@MainActor
func screenShowingMost(of rect: CGRect) -> NSScreen {
    NSScreen.screens.max { a, b in
        let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
        return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
    } ?? NSScreen.active
}

/// Full-screen images of every display taken before the overlay appears ("Freeze screen"),
/// also used as the magnifier's pixel source.
struct FrozenScreens {
    struct Shot { let frame: CGRect; let image: CGImage }
    var shots: [CGDirectDisplayID: Shot] = [:]

    func image(for screen: NSScreen) -> CGImage? { shots[screen.displayID]?.image }

    /// Crops `rect` (global Cocoa) from the frozen pixels, stitching across displays at the highest scale.
    func crop(_ rect: CGRect) -> (CGImage, CGFloat)? {
        let parts: [(CGRect, CGImage, CGFloat)] = shots.values.compactMap { shot in
            let part = rect.intersection(shot.frame)
            guard !part.isNull, part.width >= 1, part.height >= 1 else { return nil }
            let px = SelectionGeometry.pixelRect(for: part, screenFrame: shot.frame,
                                                 imageSize: CGSize(width: shot.image.width, height: shot.image.height))
            guard let cropped = ImageTools.cropped(shot.image, to: px) else { return nil }
            return (part, cropped, CGFloat(shot.image.width) / shot.frame.width)
        }
        return CaptureEngine.stitch(parts, rect: rect)
    }
}

/// Screen pixels for CaptureKit, on top of `ScreenCapturer` (which already keeps the desktop-icon covers, since
/// they sit below the floating level).
@MainActor
enum CaptureEngine {

    /// Captures every display (for freezing / the magnifier).
    static func captureAllScreens() async throws -> FrozenScreens {
        var frozen = FrozenScreens()
        for screen in NSScreen.screens {
            let img = try await ScreenCapturer.capture(screen: screen)
            frozen.shots[screen.displayID] = .init(frame: screen.frame, image: img)
        }
        return frozen
    }

    /// Composes per-display parts into one image of `rect`. A single part is returned as-is.
    nonisolated static func stitch(_ parts: [(CGRect, CGImage, CGFloat)], rect: CGRect) -> (CGImage, CGFloat)? {
        guard !parts.isEmpty else { return nil }
        if parts.count == 1, parts[0].0.size == rect.size { return (parts[0].1, parts[0].2) }
        let scale = parts.map(\.2).max() ?? 2
        let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
        guard w > 0, h > 0, let ctx = ImageTools.context(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .high
        for (part, img, _) in parts {
            ctx.draw(img, in: SelectionGeometry.stitchDestination(part: part, whole: rect, scale: scale))
        }
        guard let out = ctx.makeImage() else { return nil }
        return (out, scale)
    }
}
