import AppKit
import ShotcraftCore

/// The capture hand-off (CleanShot-style): a borderless, click-through window shows the captured image exactly
/// where it was captured, then scales and moves it — rounding its corners and gaining a soft shadow — into the
/// Quick Access card's slot. The caller reveals the card in that same frame before the stand-in disappears.
@MainActor
enum CaptureFlight {
    static let duration: TimeInterval = 0.35
    /// Room around the path for the shadow.
    private static let shadowRoom: CGFloat = 32

    /// - Parameters:
    ///   - source, target: global Cocoa rects.
    ///   - land: called on arrival with a `reveal` closure; call it once the destination can show the same picture.
    ///   - isCancelled: checked before take-off and on arrival (e.g. the card was closed meanwhile).
    ///   - completion: called exactly once — `true` when the flight ended (from `reveal`, before the stand-in is
    ///     removed, or on cancellation); `false` when there was nothing to fly (fall back to the normal entrance).
    static func fly(media: CapturedMedia, from source: CGRect, to target: CGRect, radius: CGFloat,
                    land: @escaping (_ reveal: @escaping () -> Void) -> Void,
                    isCancelled: @escaping () -> Bool,
                    completion: @escaping (Bool) -> Void) {
        guard source.width >= 1, source.height >= 1 else { completion(false); return }
        let screen = NSScreen.screens.first { $0.frame.intersects(source) } ?? NSScreen.active
        let backing = screen.backingScaleFactor
        let maxPixel = min(max(source.width, source.height) * backing, 2400)
        Thumbnailer.thumbnail(for: media.url, kind: media.kind, maxPixel: maxPixel) { image in
            guard !isCancelled(), let image else { completion(false); return }
            launch(image, from: source, to: target, radius: radius, backing: backing, land: land,
                   isCancelled: isCancelled, completion: completion)
        }
    }

    private static func launch(_ image: NSImage, from source: CGRect, to target: CGRect, radius: CGFloat, backing: CGFloat,
                               land: @escaping (_ reveal: @escaping () -> Void) -> Void,
                               isCancelled: @escaping () -> Bool,
                               completion: @escaping (Bool) -> Void) {
        let windowFrame = source.union(target).insetBy(dx: -shadowRoom, dy: -shadowRoom).integral
        let window = OverlayWindow.makePanel(windowFrame, level: OverlayWindow.quickAccessLevel)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        let host = NSView(frame: NSRect(origin: .zero, size: windowFrame.size))
        host.wantsLayer = true
        window.contentView = host

        let local = { (r: CGRect) in r.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY) }
        let from = local(source), to = local(target)

        // `holder` casts the shadow; `picture` clips the aspect-filled image to the rounding corners.
        let holder = CALayer()
        holder.shadowColor = NSColor.black.cgColor
        holder.shadowOffset = CGSize(width: 0, height: -4)
        holder.shadowRadius = 14
        holder.shadowOpacity = 0
        holder.cornerCurve = .continuous
        let picture = CALayer()
        picture.contents = image.layerContents(forContentsScale: backing)
        picture.contentsScale = backing
        picture.contentsGravity = .resizeAspectFill
        picture.minificationFilter = .trilinear
        picture.masksToBounds = true
        picture.cornerCurve = .continuous
        holder.addSublayer(picture)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(holder, picture, in: from, radius: 0)
        host.layer?.addSublayer(holder)
        CATransaction.commit()
        window.orderFrontRegardless()

        // Let the stand-in appear in place for one frame, then fly.
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(OverlayStyle.easeOut)
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    guard !isCancelled() else { window.orderOut(nil); completion(true); return }
                    land {
                        completion(true)
                        // The destination draws on this pass; drop the stand-in right after it, so both never
                        // show at once with different content.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { window.orderOut(nil) }
                    }
                }
            }
            place(holder, picture, in: to, radius: radius)
            holder.shadowOpacity = 0.3
            CATransaction.commit()
        }
    }

    private static func place(_ holder: CALayer, _ picture: CALayer, in rect: CGRect, radius: CGFloat) {
        holder.frame = rect
        holder.cornerRadius = radius
        holder.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: radius, cornerHeight: radius,
                                   transform: nil)
        picture.frame = CGRect(origin: .zero, size: rect.size)
        picture.cornerRadius = radius
    }
}
