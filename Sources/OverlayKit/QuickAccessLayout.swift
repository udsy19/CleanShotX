import CoreGraphics
import Foundation
import SuperScreenshotCore

/// Pure geometry for the Quick Access stack (no AppKit state), so it can be self-tested.
/// All rects are global Cocoa coordinates (origin bottom-left). Values are read from CleanShot X's binary unless noted.
public enum QuickAccessLayout {
    /// Card width / height — the same for every capture; the thumbnail aspect-fills (crops) the card.
    public static let aspect: CGFloat = 1.4
    /// Distance between the card and the screen frame's side edge.
    public static let sideMargin: CGFloat = 40
    /// The newest card's bottom edge sits this far above the bottom of the screen *frame* (it clears the Dock).
    public static let bottomMargin: CGFloat = 100
    /// Vertical gap between stacked cards.
    public static let spacing: CGFloat = 10
    /// Close All / Save All header (Super Screenshot's own; as wide as a card).
    public static let headerHeight: CGFloat = 30
    /// How much of the newest card stays visible while the stack is temporarily slid down.
    public static let slideDownPeek: CGFloat = 14
    /// The header with Close All / Save All appears from this many cards on.
    public static let headerThreshold = 3

    /// Card size for an "Overlay size" index: `QuickAccessSize.widths[index]` × (width / 1.4), e.g. 210×150 pt.
    public static func cardSize(sizeIndex: Int) -> CGSize {
        let width = QuickAccessSize.widths[QuickAccessSize.clamped(sizeIndex)]
        return CGSize(width: width, height: (width / aspect).rounded())
    }

    /// Side of the four circular corner buttons: 18 + 2 × size index (22 pt at the default index 2).
    public static func cornerButtonSide(sizeIndex: Int) -> CGFloat {
        18 + 2 * CGFloat(QuickAccessSize.clamped(sizeIndex))
    }

    /// Longest-side pixel size of a thumbnail that aspect-fills `card` without upscaling, so it stays sharp on a
    /// `backingScale` display even when a very wide or tall capture is cropped by the fill.
    public static func thumbnailMaxPixel(card: CGSize, media: CGSize, backingScale: CGFloat) -> CGFloat {
        guard media.width > 0, media.height > 0 else { return (max(card.width, card.height) * backingScale).rounded(.up) }
        let fill = max(card.width / media.width, card.height / media.height)
        return (max(media.width, media.height) * fill * backingScale).rounded(.up)
    }

    public struct Result: Equatable {
        /// One entry per card (newest first); nil when the card doesn't fit on screen.
        public var cards: [CGRect?]
        /// Frame of the Close All / Save All header, when shown.
        public var header: CGRect?
    }

    /// Lays out `count` cards of `size` bottom-up: card i (0 = newest) has its bottom edge at
    /// `screen.minY + 100 + i × (height + 10)`, 40 pt from the chosen side of `screen` (the screen's full frame).
    /// Cards that would reach into the menu bar (`visible.maxY`, less one gap) wait until space frees up.
    public static func layout(count: Int, cardSize size: CGSize, screen: CGRect, visible: CGRect, side: ScreenSide) -> Result {
        let x = side == .left ? screen.minX + sideMargin : screen.maxX - sideMargin - size.width
        let wantsHeader = count >= headerThreshold
        // Reserve room for the header so it never overlaps the topmost visible card.
        let top = visible.maxY - spacing - (wantsHeader ? headerHeight + spacing : 0)
        var frames: [CGRect?] = []
        var topmost: CGRect?
        for i in 0..<max(count, 0) {
            let frame = CGRect(x: x, y: screen.minY + bottomMargin + CGFloat(i) * (size.height + spacing),
                               width: size.width, height: size.height)
            // Slots only climb, so once one doesn't fit no older card does: newer cards stay visible.
            guard frame.maxY <= top else {
                frames.append(nil)
                continue
            }
            frames.append(frame)
            topmost = frame
        }
        var header: CGRect?
        if wantsHeader, let t = topmost {
            header = CGRect(x: x, y: t.maxY + spacing, width: size.width, height: headerHeight)
        }
        return Result(cards: frames, header: header)
    }

    /// `frame` moved `QuickAccessMotion.slideDistance` toward the stack's screen edge: where a card's entrance
    /// starts and its exit ends (measured).
    public static func edgeFrame(for frame: CGRect, side: ScreenSide) -> CGRect {
        frame.offsetBy(dx: side == .left ? -QuickAccessMotion.slideDistance : QuickAccessMotion.slideDistance, dy: 0)
    }

    /// Where a card sits while the stack is temporarily hidden by sliding it down: only its top edge peeks out.
    public static func slidDownFrame(for frame: CGRect, in visible: CGRect) -> CGRect {
        var f = frame
        f.origin.y = visible.minY - frame.height + slideDownPeek
        return f
    }

    /// True when a point (e.g. a drag end or swipe) is within `tolerance` of the edge the cards live on.
    public static func isAtEdge(_ point: CGPoint, of screenFrame: CGRect, side: ScreenSide, tolerance: CGFloat = 6) -> Bool {
        side == .left ? point.x <= screenFrame.minX + tolerance : point.x >= screenFrame.maxX - tolerance
    }
}

/// Quick Access motion as pure curves, fitted to a 120 Hz recording of CleanShot X's window geometry (measured).
public enum QuickAccessMotion {
    /// Entrances start, and exits end, this far toward the screen edge.
    public static let slideDistance: CGFloat = 69
    /// Entrance fade 0 → 1 (ease-out).
    public static let appearFadeDuration: TimeInterval = 0.25
    /// Exit: slide toward the edge and fade out together (ease-in).
    public static let disappearDuration: TimeInterval = 0.2
    /// Hover chrome (dim curtain + buttons) fades in/out.
    public static let hoverFade: TimeInterval = 0.15
    /// The spring is snapped to rest after this (residual < 0.1 pt per 69 pt of travel).
    public static let springDuration: TimeInterval = 0.5

    // The measured entrance overshoots a 69 pt slide by 5 pt, peaking at 0.19 s. An underdamped spring released
    // from rest peaks after half a damped period, overshooting by e^(−πζ/√(1−ζ²)): solve both for ζ (≈ 0.64) and
    // the damped frequency; the undamped period ("response") comes out ≈ 0.29 s.
    private static let overshoot = 5.0 / 69.0
    private static let peakTime = 0.19
    private static let dampingRatio: Double = {
        let l = log(overshoot)
        return -l / (Double.pi * Double.pi + l * l).squareRoot()
    }()
    private static let dampedFrequency = Double.pi / peakTime
    private static let decayRate = dampedFrequency * dampingRatio / (1 - dampingRatio * dampingRatio).squareRoot()

    /// Spring progress from 0 (start) to 1 (rest) at `t` seconds; it passes 1 (≈ 1.072 at 0.19 s) before settling.
    public static func spring(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < springDuration else { return 1 }
        let w = dampedFrequency * t
        return 1 - exp(-decayRate * t) * (cos(w) + decayRate / dampedFrequency * sin(w))
    }

    public static func easeOut(_ p: Double) -> Double {
        let c = min(max(p, 0), 1)
        return 1 - (1 - c) * (1 - c)
    }

    public static func easeIn(_ p: Double) -> Double {
        let c = min(max(p, 0), 1)
        return c * c
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

    /// `frame` when at least `minVisible` pt of it (or all of a smaller frame) shows on one of `screens`; otherwise
    /// the same-size frame moved into the first screen (a display was unplugged or rearranged), as close to where
    /// it was as possible, with its top edge on screen when it is taller than the display.
    public static func frameKeptOnScreen(_ frame: CGRect, screens: [CGRect], minVisible: CGFloat = 40) -> CGRect {
        guard let home = screens.first else { return frame }
        for s in screens {
            let i = frame.intersection(s)
            if !i.isNull, i.width >= min(minVisible, frame.width), i.height >= min(minVisible, frame.height) { return frame }
        }
        var f = frame
        f.origin.x = frame.width > home.width ? home.minX : min(max(f.minX, home.minX), home.maxX - f.width)
        f.origin.y = frame.height > home.height ? home.maxY - f.height : min(max(f.minY, home.minY), home.maxY - f.height)
        return f
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
