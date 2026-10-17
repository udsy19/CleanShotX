import CoreGraphics
import ShotcraftCore

/// Pure geometry for the Quick Access stack (no AppKit state), so it can be self-tested.
/// All rects are global Cocoa coordinates (origin bottom-left).
public enum QuickAccessLayout {
    public static let baseCardWidth: CGFloat = 200
    public static let minAspect: CGFloat = 0.45   // height / width
    public static let maxAspect: CGFloat = 1.25
    public static let margin: CGFloat = 16
    public static let spacing: CGFloat = 12
    public static let headerHeight: CGFloat = 30
    public static let headerWidth: CGFloat = 200
    /// The header with Close All / Save All appears from this many cards on.
    public static let headerThreshold = 3

    /// Clamps the user's size preference to the supported 0.6…1.4 range.
    public static func clampedScale(_ scale: Double) -> CGFloat {
        CGFloat(min(max(scale.isFinite ? scale : 1, 0.6), 1.4))
    }

    /// Card size for media of the given pixel/point size (aspect ratio is what matters).
    public static func cardSize(for mediaSize: CGSize, scale: Double) -> CGSize {
        let s = clampedScale(scale)
        let width = (baseCardWidth * s).rounded()
        var aspect: CGFloat = 0.625
        if mediaSize.width > 0, mediaSize.height > 0 { aspect = mediaSize.height / mediaSize.width }
        aspect = min(max(aspect, minAspect), maxAspect)
        return CGSize(width: width, height: (width * aspect).rounded())
    }

    public struct Result: Equatable {
        /// One entry per input card (same order); nil when the card doesn't fit on screen.
        public var cards: [CGRect?]
        /// Frame of the Close All / Save All header, when shown.
        public var header: CGRect?
    }

    /// Lays out cards bottom-up from the screen's bottom edge.
    /// - Parameter newestFirst: card sizes, index 0 = newest (placed at the bottom).
    public static func layout(newestFirst sizes: [CGSize], in visible: CGRect, side: ScreenSide, scale: Double) -> Result {
        let s = clampedScale(scale)
        let m = (margin * s).rounded(), gap = (spacing * s).rounded()
        let wantsHeader = sizes.count >= headerThreshold
        let headerH = (headerHeight * s).rounded()
        // Reserve room for the header so it never overlaps the topmost visible card.
        let top = visible.maxY - m - (wantsHeader ? headerH + gap : 0)
        var y = visible.minY + m
        var frames: [CGRect?] = []
        var topmost: CGRect?
        var full = false
        for size in sizes {
            let x = side == .left ? visible.minX + m : visible.maxX - m - size.width
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            if full || frame.maxY > top {
                full = true          // keep newer cards visible; older ones wait until space frees up
                frames.append(nil)
                continue
            }
            frames.append(frame)
            topmost = frame
            y = frame.maxY + gap
        }
        var header: CGRect?
        if wantsHeader, let t = topmost {
            let w = (headerWidth * s).rounded()
            let x = side == .left ? visible.minX + m : visible.maxX - m - w
            header = CGRect(x: x, y: t.maxY + gap, width: w, height: headerH)
        }
        return Result(cards: frames, header: header)
    }

    /// Where a card starts its slide-in (and ends its slide-out): just past the configured screen edge.
    public static func offscreenFrame(for frame: CGRect, in visible: CGRect, side: ScreenSide) -> CGRect {
        var f = frame
        f.origin.x = side == .left ? visible.minX - frame.width - 8 : visible.maxX + 8
        return f
    }

    /// True when a point (e.g. a drag end or swipe) is within `tolerance` of the edge the cards live on.
    public static func isAtEdge(_ point: CGPoint, of screenFrame: CGRect, side: ScreenSide, tolerance: CGFloat = 6) -> Bool {
        side == .left ? point.x <= screenFrame.minX + tolerance : point.x >= screenFrame.maxX - tolerance
    }
}

/// Pure geometry for pinned screenshots.
public enum PinGeometry {
    public static let minMagnification: CGFloat = 0.1
    public static let maxMagnification: CGFloat = 5

    /// Initial magnification so the image fits within `fraction` of the visible frame (never upscales).
    public static func fittingMagnification(imageSize: CGSize, visible: CGRect, fraction: CGFloat = 0.85) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let fit = min(visible.width * fraction / imageSize.width, visible.height * fraction / imageSize.height)
        return max(minMagnification, min(1, fit))
    }

    /// Resizes `frame` to `imageSize × magnification`, keeping `anchor` (a global point inside the frame) fixed.
    public static func scaled(frame: CGRect, imageSize: CGSize, magnification: CGFloat, anchor: CGPoint) -> CGRect {
        let m = min(max(magnification, minMagnification), maxMagnification)
        let newSize = CGSize(width: max(1, (imageSize.width * m).rounded()), height: max(1, (imageSize.height * m).rounded()))
        let fx = frame.width > 0 ? (anchor.x - frame.minX) / frame.width : 0.5
        let fy = frame.height > 0 ? (anchor.y - frame.minY) / frame.height : 0.5
        return CGRect(x: (anchor.x - fx * newSize.width).rounded(), y: (anchor.y - fy * newSize.height).rounded(),
                      width: newSize.width, height: newSize.height)
    }
}
