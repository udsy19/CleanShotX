import Foundation
import CoreGraphics
import Vision

/// What the overlay needs after each processed frame.
struct ScrollUpdate {
    var event: ScrollStitcher.Event
    /// nil while the orientation is still being detected.
    var axis: ScrollAxis?
    var frames: Int
    var pixelSize: CGSize
    var parts: [CGImage]
    var partsAxis: ScrollAxis
}

/// Owns the stitcher(s) of a session. Every method must be called on `queue`.
/// With orientation `nil` (Auto), a vertical and a horizontal stitcher run side by side until one of them
/// matches a movement; the other is then dropped.
final class ScrollEngine: @unchecked Sendable {   // confined to `queue`
    let queue = DispatchQueue(label: "shotcraft.textkit.scrolling", qos: .userInitiated)
    private var candidates: [ScrollStitcher]
    private(set) var locked: ScrollStitcher?

    init(axis: ScrollAxis?, maxLength: Int) {
        let axes: [ScrollAxis] = axis.map { [$0] } ?? [.vertical, .horizontal]
        candidates = axes.map { ScrollStitcher(axis: $0, maxLength: maxLength) }
        for s in candidates { s.hint = VisionRegistration.offset }
        if candidates.count == 1 { locked = candidates[0] }
    }

    /// Forces an orientation (e.g. when auto-scroll starts) unless one was already detected.
    func lock(_ axis: ScrollAxis) {
        guard locked == nil, let s = candidates.first(where: { $0.axis == axis }) else { return }
        locked = s
        candidates = [s]
    }

    var hasFrames: Bool { (locked ?? candidates.first)?.acceptedFrames ?? 0 > 0 }

    func process(_ image: CGImage) -> ScrollUpdate {
        let event: ScrollStitcher.Event
        if let s = locked {
            event = s.add(image)
        } else {
            let events = candidates.map { $0.add(image) }
            if let i = events.firstIndex(where: { if case .appended = $0 { return true }; return $0 == .limitReached }) {
                locked = candidates[i]
                candidates = [candidates[i]]
                event = events[i]
            } else {
                // Report the most informative outcome while detecting.
                event = events.first { $0 == .noOverlap } ?? events.first { $0 == .reversed } ?? events[0]
            }
        }
        let s = locked ?? candidates[0]
        return ScrollUpdate(event: event, axis: locked?.axis, frames: s.acceptedFrames, pixelSize: s.pixelSize,
                            parts: s.parts(), partsAxis: s.axis)
    }

    func render() -> CGImage? { (locked ?? candidates.first)?.render() }
}

/// Vision's translational registration as an offset hint for frames pixel matching couldn't align.
enum VisionRegistration {
    static func offset(_ previous: CGImage, _ next: CGImage, axis: ScrollAxis) -> Int? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: next, options: [:])
        let handler = VNImageRequestHandler(cgImage: previous, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }
        let t = obs.alignmentTransform
        let v = axis == .vertical ? t.ty : t.tx
        guard v.isFinite, abs(v) >= 1 else { return nil }
        return Int(v.rounded())
    }
}
