import AppKit
import QuartzCore

/// Short, quiet transitions for the capture UI. Every animation is skipped when "Reduce motion" is on.
@MainActor
enum OverlayMotion {
    static let overlayFadeIn: TimeInterval = 0.12
    static let overlayFadeOut: TimeInterval = 0.12
    static let hoverMove: CFTimeInterval = 0.14
    static let decorationFade: CFTimeInterval = 0.12

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Animates `window.alphaValue` (instantly with Reduce motion), then runs `completion`.
    static func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval,
                     completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !reduced, duration > 0 else {
            window.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: alpha > window.alphaValue ? .easeOut : .easeIn)
            window.animator().alphaValue = alpha
        }, completionHandler: {
            guard let completion else { return }
            MainActor.assumeIsolated { completion() }
        })
    }

    /// 0…1 progress of a transition that started at `start`, eased out (1 when motion is reduced).
    static func progress(since start: CFTimeInterval, duration: CFTimeInterval, now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        guard !reduced, duration > 0 else { return 1 }
        let t = min(max((now - start) / duration, 0), 1)
        return CGFloat(1 - pow(1 - t, 3))
    }

    /// A quick white flash over `screen` after a fullscreen capture (shutter feedback). Above the floating
    /// level, so it never shows up in captures.
    static func shutterFlash(on screen: NSScreen) {
        guard !reduced else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = overlayWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.12)
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        fade(panel, to: 0, duration: 0.25) {
            panel.orderOut(nil)
            panel.close()
        }
    }
}

/// Drives redraws while overlay transitions are in flight: a display-rate timer that runs only until the
/// latest transition ends, so an idle overlay costs nothing.
@MainActor
final class OverlayAnimationClock {
    private var timer: Timer?
    private var until: CFTimeInterval = 0
    private let onFrame: @MainActor () -> Void

    init(onFrame: @escaping @MainActor () -> Void) { self.onFrame = onFrame }

    /// Keeps frames coming for `duration` from now.
    func run(for duration: CFTimeInterval) {
        guard !OverlayMotion.reduced else { return }
        until = max(until, CACurrentMediaTime() + duration)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` keeps it running during mouse tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        onFrame()
        if CACurrentMediaTime() >= until { stop() }
    }
}
