import AppKit

/// Moves and fades Quick Access panels frame by frame along the measured `QuickAccessMotion` curves, in step with
/// the display (up to 120 Hz on ProMotion). Position and alpha are separate tracks, so a reflow can retarget a card
/// mid-entrance without cutting its fade-in.
@MainActor
final class PanelMotion: NSObject {
    static let shared = PanelMotion()

    enum Curve {
        /// `QuickAccessMotion.spring` — entrances and stack reflows.
        case spring
        case easeIn(TimeInterval)
        case easeOut(TimeInterval)

        var duration: TimeInterval {
            switch self {
            case .spring: QuickAccessMotion.springDuration
            case .easeIn(let d), .easeOut(let d): d
            }
        }

        /// 0 at the start, exactly 1 once `duration` has passed (the spring overshoots 1 on the way).
        func progress(at t: TimeInterval) -> Double {
            switch self {
            case .spring: QuickAccessMotion.spring(t)
            case .easeIn(let d): QuickAccessMotion.easeIn(d > 0 ? t / d : 1)
            case .easeOut(let d): QuickAccessMotion.easeOut(d > 0 ? t / d : 1)
            }
        }
    }

    private struct Track<Value> {
        let panel: NSWindow
        let from: Value
        let to: Value
        let curve: Curve
        let start: CFTimeInterval
        let completion: ((Bool) -> Void)?
    }

    private var moves: [ObjectIdentifier: Track<CGRect>] = [:]
    private var fades: [ObjectIdentifier: Track<CGFloat>] = [:]
    private var link: CADisplayLink?

    /// Moves `panel` from where it is to `frame`. A move already running is replaced (its completion gets `false`).
    func move(_ panel: NSWindow, to frame: CGRect, curve: Curve, completion: ((Bool) -> Void)? = nil) {
        let replaced = moves.updateValue(Track(panel: panel, from: panel.frame, to: frame, curve: curve,
                                               start: CACurrentMediaTime(), completion: completion),
                                         forKey: ObjectIdentifier(panel))
        startTicking(on: panel)
        replaced?.completion?(false)
    }

    /// Fades `panel` from its current alpha to `alpha`. A fade already running is replaced (its completion gets `false`).
    func fade(_ panel: NSWindow, to alpha: CGFloat, curve: Curve, completion: ((Bool) -> Void)? = nil) {
        let replaced = fades.updateValue(Track(panel: panel, from: panel.alphaValue, to: alpha, curve: curve,
                                               start: CACurrentMediaTime(), completion: completion),
                                         forKey: ObjectIdentifier(panel))
        startTicking(on: panel)
        replaced?.completion?(false)
    }

    /// Cancels the panel's move (its completion gets `false`) and puts it at `frame` at once.
    func place(_ panel: NSWindow, at frame: CGRect) {
        let replaced = moves.removeValue(forKey: ObjectIdentifier(panel))
        panel.setFrame(frame, display: true)
        replaced?.completion?(false)
    }

    /// Where the panel's running move ends (nil when it isn't moving).
    func destination(of panel: NSWindow) -> CGRect? { moves[ObjectIdentifier(panel)]?.to }

    /// The alpha the panel's running fade ends at (nil when it isn't fading).
    func alphaTarget(of panel: NSWindow) -> CGFloat? { fades[ObjectIdentifier(panel)]?.to }

    /// Jumps the panel's move and fade to their end states (completions get `true`).
    func finish(_ panel: NSWindow) {
        let id = ObjectIdentifier(panel)
        let move = moves.removeValue(forKey: id), fade = fades.removeValue(forKey: id)
        if let move { Self.setFrame(move.to, of: panel) }
        if let fade { panel.alphaValue = fade.to }
        move?.completion?(true)
        fade?.completion?(true)
    }

    private func startTicking(on panel: NSWindow) {
        guard link == nil else { return }
        guard let screen = panel.screen ?? NSScreen.screens.first else {
            // No display to sync with (nothing can be visible): land the panel on the next turn.
            DispatchQueue.main.async { [weak panel] in if let panel { self.finish(panel) } }
            return
        }
        let l = screen.displayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var finished: [(Bool) -> Void] = []
        for (id, track) in moves {
            let elapsed = now - track.start
            let p = CGFloat(track.curve.progress(at: elapsed))
            let f = track.from, t = track.to
            Self.setFrame(CGRect(x: f.minX + (t.minX - f.minX) * p, y: f.minY + (t.minY - f.minY) * p,
                                 width: f.width + (t.width - f.width) * p, height: f.height + (t.height - f.height) * p),
                          of: track.panel)
            if elapsed >= track.curve.duration {
                moves[id] = nil
                if let c = track.completion { finished.append(c) }
            }
        }
        for (id, track) in fades {
            let elapsed = now - track.start
            track.panel.alphaValue = track.from + (track.to - track.from) * CGFloat(track.curve.progress(at: elapsed))
            if elapsed >= track.curve.duration {
                fades[id] = nil
                if let c = track.completion { finished.append(c) }
            }
        }
        if moves.isEmpty && fades.isEmpty {
            link.invalidate()
            self.link = nil
        }
        finished.forEach { $0(true) }
    }

    private static func setFrame(_ frame: CGRect, of panel: NSWindow) {
        if frame.size == panel.frame.size { panel.setFrameOrigin(frame.origin) } else { panel.setFrame(frame, display: true) }
    }
}
