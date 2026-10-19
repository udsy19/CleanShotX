import CoreGraphics
import Foundation
import ScreenCaptureKit
import SuperScreenshotCore
import CaptureKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
func registerCaptureKitTests() {
    typealias G = SelectionGeometry

    SelfTest.cases.append(("CaptureKit.captureFailures", {
        // Permission problems get the "Open System Settings" treatment; a stale cache that returns nothing too.
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
        check(ScreenCapturer.classified(declined) as? ScreenCapturer.CaptureError == .permissionDenied, "SCStream userDeclined → permission problem")
        check(ScreenCapturer.CaptureError.permissionDenied.isPermissionProblem && ScreenCapturer.CaptureError.blank.isPermissionProblem,
              "denied and blank both point at System Settings")
        check(!ScreenCapturer.CaptureError.timedOut.isPermissionProblem && !ScreenCapturer.CaptureError.noWindow.isPermissionProblem,
              "other failures are ordinary errors")
        check(ScreenCapturer.classified(ScreenCapturer.CaptureError.timedOut) as? ScreenCapturer.CaptureError == .timedOut, "own errors pass through")
        for e: ScreenCapturer.CaptureError in [.noDisplay, .noWindow, .failed, .permissionDenied, .blank, .timedOut] {
            check(!(e.errorDescription ?? "").isEmpty, "\(e) has a message")
        }

        // Empty pixels (what a revoked permission yields) are detected; real content is not.
        let n = 64
        let ctx = ImageTools.context(width: n, height: n)!
        check(ImageTools.isFullyTransparent(ctx.makeImage()!), "all-transparent image detected")
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        check(!ImageTools.isFullyTransparent(ctx.makeImage()!), "an opaque black image is content, not a failure")
        let half = ImageTools.context(width: n, height: n)!
        half.setFillColor(CGColor(gray: 1, alpha: 1)); half.fill(CGRect(x: 0, y: 0, width: n / 2, height: n))
        check(!ImageTools.isFullyTransparent(half.makeImage()!), "partly transparent image is content")
        let opaque = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        check(!ImageTools.isFullyTransparent(opaque.makeImage()!), "images without alpha are never 'empty'")
    }))

    SelfTest.cases.append(("CaptureKit.hugeCaptures", {
        // Three 5K displays side by side fit; absurd sizes fail with a clear message instead of a 4 GB allocation.
        check((try? ImageTools.validateSize(width: 3 * 5120, height: 2880)) != nil, "3 × 5K all-in-one is allowed")
        var message = ""
        do { try ImageTools.validateSize(width: 40_000, height: 40_000) } catch { message = error.localizedDescription }
        check(message.contains("40000 × 40000") && message.contains("smaller area"), "too-large error names the size and the fix: \(message)")
        let start = Date()
        check(ImageTools.context(width: 40_000, height: 40_000) == nil, "no bitmap is attempted for an absurd size")
        check(Date().timeIntervalSince(start) < 0.5, "…and it is refused immediately")
        check((try? ImageTools.validateSize(width: 0, height: 10)) == nil, "zero size refused")
        check((try? ImageTools.validateSize(width: Int.max, height: 2)) == nil, "overflowing size refused")
        check(ImageError.outOfMemory(width: 1, height: 2).errorDescription?.contains("memory") == true, "out-of-memory text")
    }))

    SelfTest.cases.append(("CaptureKit.timeout", {
        // A capture that never returns must not leave the overlay or the service stuck: it is abandoned on time.
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var slow: Error?
        nonisolated(unsafe) var fast: Int?
        nonisolated(unsafe) var waited: TimeInterval = 0
        Task.detached {
            let start = Date()
            do {
                // Like SCScreenshotManager, this work ignores cancellation: it just keeps going for a second.
                _ = try await withTimeout(seconds: 0.05) {
                    let deadline = Date().addingTimeInterval(1)
                    while Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                    return 1
                }
            } catch { slow = error }
            waited = Date().timeIntervalSince(start)
            fast = try? await withTimeout(seconds: 1) { 42 }
            done.signal()
        }
        check(done.wait(timeout: .now() + 5) == .success, "timeout harness finished")
        check(slow as? ScreenCapturer.CaptureError == .timedOut, "hung operation reports a timeout")
        check(waited < 0.5, "the caller is released at the timeout, not when the hung work ends (\(Int(waited * 1000)) ms)")
        check(fast == 42, "fast operation returns its result")
    }))

    SelfTest.cases.append(("CaptureKit.dragRect", {
        check(G.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30)) == CGRect(x: 10, y: 10, width: 30, height: 20), "plain drag")
        check(G.rect(from: CGPoint(x: 40, y: 30), to: CGPoint(x: 10, y: 10)) == CGRect(x: 10, y: 10, width: 30, height: 20), "reverse drag normalizes")
        check(G.rect(from: .zero, to: CGPoint(x: 10, y: -4), square: true) == CGRect(x: 0, y: -10, width: 10, height: 10), "shift = square, keeps direction")
        check(G.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 60, y: 70), fromCenter: true) == CGRect(x: 40, y: 30, width: 20, height: 40), "option = from center")
        check(G.rect(from: .zero, to: CGPoint(x: 160, y: 10), ratio: 16.0 / 9.0) == CGRect(x: 0, y: 0, width: 160, height: 90), "16:9 lock (width dominant)")
        check(G.rect(from: .zero, to: CGPoint(x: -10, y: -90), ratio: 16.0 / 9.0) == CGRect(x: -160, y: -90, width: 160, height: 90), "16:9 lock (height dominant)")
    }))

    SelfTest.cases.append(("CaptureKit.resize", {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(G.resize(r, handle: .right, to: CGPoint(x: 150, y: 50)) == CGRect(x: 0, y: 0, width: 150, height: 100), "right edge")
        check(G.resize(r, handle: .left, to: CGPoint(x: 150, y: 50)) == CGRect(x: 100, y: 0, width: 50, height: 100), "left edge flips past right")
        check(G.resize(r, handle: .top, to: CGPoint(x: 0, y: 130)) == CGRect(x: 0, y: 0, width: 100, height: 130), "top edge (Cocoa maxY)")
        check(G.resize(r, handle: .right, to: CGPoint(x: 120, y: 50), fromCenter: true) == CGRect(x: -20, y: 0, width: 140, height: 100), "option resizes symmetrically")
        let wide = CGRect(x: 0, y: 0, width: 100, height: 50)
        check(G.resize(wide, handle: .topRight, to: CGPoint(x: 200, y: 60), ratio: 2) == CGRect(x: 0, y: 0, width: 200, height: 100), "corner with ratio keeps anchor")
        check(G.resize(wide, handle: .bottomLeft, to: CGPoint(x: -100, y: 0), ratio: 2) == CGRect(x: -100, y: -50, width: 200, height: 100), "opposite corner anchor")
        check(G.resize(wide, handle: .right, to: CGPoint(x: 200, y: 25), ratio: 2) == CGRect(x: 0, y: -25, width: 200, height: 100), "edge with ratio centers the other axis")
    }))

    SelfTest.cases.append(("CaptureKit.clampNudge", {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(G.clamped(CGRect(x: 90, y: -5, width: 20, height: 20), to: bounds) == CGRect(x: 80, y: 0, width: 20, height: 20), "moved inside")
        check(G.clamped(CGRect(x: -10, y: 0, width: 300, height: 20), to: bounds).width == 100, "shrunk to bounds")
        check(G.nudged(CGRect(x: 10, y: 10, width: 10, height: 10), dx: 10, dy: 0, resize: false, within: bounds).minX == 20, "nudge moves")
        let grown = G.nudged(CGRect(x: 10, y: 10, width: 10, height: 10), dx: 1, dy: -1, resize: true, within: bounds)
        check(grown == CGRect(x: 10, y: 9, width: 11, height: 11), "option-arrow resizes keeping top-left")
        check(G.resized(CGRect(x: 10, y: 50, width: 10, height: 10), to: CGSize(width: 30, height: 20), within: bounds)
              == CGRect(x: 10, y: 40, width: 30, height: 20), "W×H fields keep the top-left corner")
    }))

    SelfTest.cases.append(("CaptureKit.snapping", {
        check(G.snap(103, to: [100, 200]) == 100, "snaps within threshold")
        check(G.snap(110, to: [100, 200]) == nil, "no snap beyond threshold")
        check(G.snap(152, to: [150, 155]) == 150, "nearest candidate wins")
        check(G.snap(CGPoint(x: 97, y: 51), xs: [100], ys: [300]) == CGPoint(x: 100, y: 51), "point snaps per axis")
        let moved = G.snapMoving(CGRect(x: 5, y: 0, width: 50, height: 50), xs: [0, 300], ys: [])
        check(moved.minX == 0, "moving rect snaps nearest edge")
        let right = G.snapMoving(CGRect(x: 245, y: 0, width: 50, height: 50), xs: [0, 300], ys: [])
        check(right.maxX == 300, "moving rect snaps max edge")
    }))

    SelfTest.cases.append(("CaptureKit.handles", {
        let r = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(G.handle(at: CGPoint(x: 1, y: 1), in: r) == .bottomLeft, "bottom-left corner")
        check(G.handle(at: CGPoint(x: 99, y: 100), in: r) == .topRight, "top-right corner")
        check(G.handle(at: CGPoint(x: 50, y: 101), in: r) == .top, "top edge handle")
        check(G.handle(at: CGPoint(x: 30, y: 2), in: r) == .bottom, "bottom edge band")
        check(G.handle(at: CGPoint(x: 50, y: 50), in: r) == nil, "inside is not a handle")
        check(SelectionHandle.top.point(in: r) == CGPoint(x: 50, y: 100), "top handle sits at maxY")
    }))

    SelfTest.cases.append(("CaptureKit.pixels", {
        // Primary 100×50 pt display at 2x.
        let main = CGRect(x: 0, y: 0, width: 100, height: 50)
        check(G.pixelRect(for: CGRect(x: 10, y: 10, width: 20, height: 20), screenFrame: main, imageSize: CGSize(width: 200, height: 100))
              == CGRect(x: 20, y: 40, width: 40, height: 40), "cocoa → top-left pixel rect")
        // Secondary display to the right, at 1x and offset upward.
        let side = CGRect(x: 100, y: 20, width: 80, height: 60)
        check(G.pixelRect(for: CGRect(x: 90, y: 30, width: 30, height: 10), screenFrame: side, imageSize: CGSize(width: 80, height: 60))
              == CGRect(x: 0, y: 40, width: 20, height: 10), "clipped to display, display-local")
        check(G.pixelRect(for: CGRect(x: 500, y: 500, width: 1, height: 1), screenFrame: main, imageSize: CGSize(width: 200, height: 100)).isNull, "off-display is null")
        check(G.stitchDestination(part: CGRect(x: 100, y: 30, width: 20, height: 10), whole: CGRect(x: 90, y: 30, width: 30, height: 10), scale: 2)
              == CGRect(x: 20, y: 0, width: 40, height: 20), "stitch offset at max scale")
    }))

    SelfTest.cases.append(("CaptureKit.aspect", {
        let big = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        check(G.applying(.ratio(1, 1), to: CGRect(x: 0, y: 0, width: 200, height: 100), within: big) == CGRect(x: 50, y: 0, width: 100, height: 100), "1:1 fits inside, centered")
        check(G.applying(.ratio(16, 9), to: CGRect(x: 0, y: 0, width: 160, height: 160), within: big).height == 90, "16:9 trims height")
        let small = CGRect(x: 0, y: 0, width: 640, height: 400)
        let fitted = G.applying(.size(1280, 720), to: CGRect(x: 100, y: 100, width: 10, height: 10), within: small)
        check(fitted.width <= 640 && abs(fitted.width / fitted.height - 16.0 / 9.0) < 0.001 && small.contains(fitted), "oversized preset shrinks, keeps ratio")
        check(AspectRatio.freeform.value == nil && AspectRatio.ratio(4, 3).value == 4.0 / 3.0, "ratio values")
        for a in AspectRatio.ratios + AspectRatio.sizes {
            check(AspectRatio(storageString: a.storageString) == a, "storage roundtrip \(a.title)")
        }
        check(AspectRatio(storageString: "garbage") == nil, "invalid storage")
        check(AspectRatio.ratio(16, 9).title == "16:9" && AspectRatio.size(1920, 1080).title == "1920 × 1080", "titles")
    }))

    SelfTest.cases.append(("CaptureKit.formatting", {
        check(G.hexString(r: 0.227, g: 0.482, b: 1.0) == "#3A7BFF", "hex uppercase")
        check(G.hexString(r: -1, g: 2, b: 0.5) == "#00FF80", "hex clamps")
        check(G.dimensionString(CGSize(width: 1279.6, height: 720.2)) == "1280 × 720", "dimension rounding")
    }))

    SelfTest.cases.append(("CaptureKit.layout", {
        let canvas = CGSize(width: 200, height: 100)
        check(G.placement(of: CGSize(width: 100, height: 100), in: canvas, mode: .fill) == CGRect(x: 0, y: -50, width: 200, height: 200), "aspect fill")
        check(G.placement(of: CGSize(width: 100, height: 100), in: canvas, mode: .fit) == CGRect(x: 50, y: 0, width: 100, height: 100), "aspect fit")
        check(G.placement(of: CGSize(width: 10, height: 10), in: canvas, mode: .center) == CGRect(x: 95, y: 45, width: 10, height: 10), "center")
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let below = G.placeBelow(CGSize(width: 200, height: 40), anchor: CGRect(x: 400, y: 300, width: 200, height: 200), bounds: bounds)
        check(below == CGRect(x: 400, y: 250, width: 200, height: 40), "toolbar below selection")
        let above = G.placeBelow(CGSize(width: 200, height: 40), anchor: CGRect(x: 400, y: 0, width: 200, height: 200), bounds: bounds)
        check(above.minY == 210, "toolbar flips above when no room below")
        let inside = G.placeBelow(CGSize(width: 200, height: 40), anchor: bounds, bounds: bounds)
        check(bounds.contains(inside), "fullscreen selection keeps toolbar on screen")
    }))

    SelfTest.cases.append(("CaptureKit.badge", {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 80, height: 20)
        let sel = CGRect(x: 100, y: 100, width: 300, height: 200)
        let br = G.badgeFrame(size: size, cursor: CGPoint(x: 400, y: 100), selection: sel, bounds: bounds)
        check(br == CGRect(x: 412, y: 68, width: 80, height: 20), "outside the dragged bottom-right corner")
        let tl = G.badgeFrame(size: size, cursor: CGPoint(x: 100, y: 300), selection: sel, bounds: bounds)
        check(tl == CGRect(x: 8, y: 312, width: 80, height: 20), "outside the dragged top-left corner")
        let edge = G.badgeFrame(size: size, cursor: CGPoint(x: 995, y: 2), selection: CGRect(x: 500, y: 2, width: 495, height: 400), bounds: bounds)
        check(bounds.insetBy(dx: 4, dy: 4).contains(edge), "never leaves the screen at a corner")
        let full = G.badgeFrame(size: size, cursor: CGPoint(x: 1000, y: 800), selection: bounds, bounds: bounds)
        check(bounds.insetBy(dx: 4, dy: 4).contains(full), "fullscreen drag keeps the badge on screen")
    }))
}
