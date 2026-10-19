import Foundation
import CoreGraphics
import CoreMedia
import AppKit
import SuperScreenshotCore

/// Pure, side-effect-free helpers for the recording pipeline (covered by SuperScreenshotSelfTest).
public enum RecordingMath {

    // MARK: Time

    /// "0:07", "1:02", "1:02:03".
    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Dimensions

    /// Rounds a point size to pixels at `scale` and down to even numbers (H.264/HEVC 4:2:0 requirement).
    /// Never returns less than 2×2.
    public static func evenPixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        func even(_ v: CGFloat) -> Int { max(2, Int((v * scale).rounded(.down)) & ~1) }
        return (even(points.width), even(points.height))
    }

    /// Size scaled so its width is at most `maxWidth` (0 = unlimited), keeping aspect ratio.
    public static func fitted(_ size: CGSize, maxWidth: Int) -> CGSize {
        guard maxWidth > 0, size.width > CGFloat(maxWidth), size.width > 0 else { return size }
        let f = CGFloat(maxWidth) / size.width
        return CGSize(width: CGFloat(maxWidth), height: max(1, (size.height * f).rounded()))
    }

    /// `rect` resized to `size` around its centre, then shrunk/shifted to stay inside `bounds`.
    public static func resized(_ rect: CGRect, to size: CGSize, within bounds: CGRect) -> CGRect {
        let w = min(bounds.width, max(1, size.width)), h = min(bounds.height, max(1, size.height))
        var r = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        r.origin.x = min(max(bounds.minX, r.minX), bounds.maxX - w)
        r.origin.y = min(max(bounds.minY, r.minY), bounds.maxY - h)
        return r.integral
    }

    /// Largest rect of aspect `ratio` (w/h) that fits in `rect`, centred on it, kept inside `bounds`.
    public static func constrained(_ rect: CGRect, toAspect ratio: CGFloat, within bounds: CGRect) -> CGRect {
        guard ratio > 0, rect.width > 0, rect.height > 0 else { return rect }
        var size = rect.size
        if size.width / size.height > ratio { size.width = size.height * ratio } else { size.height = size.width / ratio }
        return resized(rect, to: CGSize(width: size.width.rounded(), height: size.height.rounded()), within: bounds)
    }

    /// Origin of the pre-record panel: centred in the area when it fits with a margin, otherwise
    /// below the area, above it, or inside its bottom edge — always within `bounds`.
    public static func setupPanelOrigin(panel: CGSize, area: CGRect, bounds: CGRect, margin: CGFloat = 24) -> CGPoint {
        let fitsInside = area.width >= panel.width + margin * 2 && area.height >= panel.height + margin * 2
        var x = area.midX - panel.width / 2
        var y: CGFloat
        if fitsInside { y = area.midY - panel.height / 2 }
        else if area.minY - 12 - panel.height >= bounds.minY + 8 { y = area.minY - 12 - panel.height }
        else if area.maxY + 12 + panel.height <= bounds.maxY - 8 { y = area.maxY + 12 }
        else { y = area.minY + 12 }
        x = min(max(x, bounds.minX + 8), bounds.maxX - panel.width - 8)
        y = min(max(y, bounds.minY + 8), bounds.maxY - panel.height - 8)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    // MARK: Export resolutions

    /// Export presets ("4k", "1440p", …) by short-side pixel count.
    public static let exportPresets: [(title: String, shortSide: Int)] =
        [("4k", 2160), ("1440p", 1440), ("1080p", 1080), ("720p", 720), ("480p", 480), ("360p", 360), ("240p", 240)]

    /// Scale factor (≤ 1) that brings `source`'s short side down to `shortSide`; 1 for 0 (= original).
    public static func exportScale(source: CGSize, shortSide: Int) -> Double {
        let side = min(source.width, source.height)
        guard shortSide > 0, side > 0 else { return 1 }
        return min(1, Double(shortSide) / Double(side))
    }

    /// Presets strictly smaller than the source, as (title, shortSide, output size) — the source itself is "Original".
    public static func exportOptions(for source: CGSize) -> [(title: String, shortSide: Int, size: (width: Int, height: Int))] {
        let original = evenPixelSize(points: source, scale: 1)
        var out: [(title: String, shortSide: Int, size: (width: Int, height: Int))] = [("Original", 0, original)]
        for p in exportPresets where CGFloat(p.shortSide) < min(source.width, source.height) {
            out.append((p.title, p.shortSide, evenPixelSize(points: source, scale: CGFloat(exportScale(source: source, shortSide: p.shortSide)))))
        }
        return out
    }

    // MARK: Encoding

    public enum Codec: String, Sendable { case h264, hevc }

    /// HEVC for "original" quality and for frames beyond the H.264 level limit (4096 px per side).
    public static func codec(for quality: VideoQuality, width: Int, height: Int) -> Codec {
        if quality == .original || width > 4096 || height > 4096 { return .hevc }
        return .h264
    }

    static func bitsPerPixel(_ quality: VideoQuality) -> Double {
        switch quality {
        case .low: 0.02
        case .medium: 0.04
        case .high: 0.07
        case .original: 0.12
        }
    }

    /// Average video bit rate in bits/s for a screen recording.
    public static func videoBitrate(width: Int, height: Int, fps: Int, quality: VideoQuality) -> Int {
        let f = Double(max(1, fps))
        let raw = Double(width * height) * bitsPerPixel(quality) * 30 * pow(f / 30, 0.6)
        return Int(min(120_000_000, max(500_000, raw)))
    }

    /// AAC bit rate for one audio track.
    public static func audioBitrate(mono: Bool) -> Int { mono ? 64_000 : 128_000 }

    /// Estimated file size in bytes (≈1.5 % container overhead).
    public static func estimatedFileSize(videoBitrate: Int, audioBitrates: [Int], duration: TimeInterval) -> Int64 {
        let bits = Double(videoBitrate + audioBitrates.reduce(0, +)) * max(0, duration)
        return Int64((bits / 8 * 1.015).rounded())
    }

    // MARK: GIF

    /// GIF delays are stored in 1/100 s; browsers clamp anything below 2 cs, so 50 fps is the ceiling.
    public static func clampedGIFFPS(_ fps: Int) -> Int { min(50, max(1, fps)) }

    /// Sample times (seconds) for `duration` at `fps`, starting at 0 and never reaching `duration`.
    public static func gifFrameTimes(duration: TimeInterval, fps: Int) -> [TimeInterval] {
        guard duration > 0 else { return [] }
        let step = 1 / Double(clampedGIFFPS(fps))
        let count = max(1, Int((duration / step).rounded(.up)))
        return (0..<count).map { Double($0) * step }.filter { $0 < duration || $0 == 0 }
    }

    /// Per-frame delays in seconds, quantized to centiseconds with error diffusion so that the
    /// sum stays within half a centisecond of `count / fps`.
    public static func gifFrameDelays(count: Int, fps: Int) -> [Double] {
        guard count > 0 else { return [] }
        let ideal = 100 / Double(clampedGIFFPS(fps))   // centiseconds per frame
        var out: [Double] = []
        out.reserveCapacity(count)
        var exact = 0.0, emitted = 0
        for _ in 0..<count {
            exact += ideal
            let target = Int(exact.rounded())
            let cs = max(2, target - emitted)
            emitted += cs
            out.append(Double(cs) / 100)
        }
        return out
    }

    /// Index of the frame showing at `time` for frames lasting `delays` (clamped to the last frame).
    public static func frameIndex(at time: Double, delays: [Double]) -> Int {
        guard !delays.isEmpty else { return 0 }
        var t = 0.0
        for (i, d) in delays.enumerated() {
            t += d
            if time < t - 1e-9 { return i }
        }
        return delays.count - 1
    }

    // MARK: Keystrokes

    /// "⌃⌥⇧⌘K" style label; modifiers in the macOS menu order.
    public static func keystrokeLabel(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    /// Whether a key press is a shortcut (shown on its own) rather than plain typing (accumulated).
    public static func isShortcut(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    // MARK: Disk

    /// Recording stops below this much free space.
    public static let minimumFreeDiskBytes: Int64 = 500 * 1024 * 1024

    public static func isDiskNearlyFull(availableBytes: Int64) -> Bool { availableBytes < minimumFreeDiskBytes }

    public static func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Pause-aware elapsed-time clock (the `PausableTimer` of the original). Pure value type.
public struct RecordingClock: Sendable {
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?

    public init() {}

    public var isRunning: Bool { runningSince != nil }

    public mutating func start(at date: Date = Date()) {
        accumulated = 0
        runningSince = date
    }

    public mutating func pause(at date: Date = Date()) {
        guard let since = runningSince else { return }
        accumulated += date.timeIntervalSince(since)
        runningSince = nil
    }

    public mutating func resume(at date: Date = Date()) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    public func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }
}


/// Pause bookkeeping on the capture clock. Samples are kept or dropped by their own timestamp (not by
/// arrival time), so frames and audio buffers that were captured before Pause but delivered after it still
/// land in the file, and nothing captured while paused leaks in after Resume.
public struct PauseTimeline: Sendable {
    private var intervals: [CMTimeRange] = []
    private var openStart: CMTime?

    public init() {}

    public var isPaused: Bool { openStart != nil }

    public mutating func pause(at t: CMTime) {
        guard openStart == nil else { return }
        openStart = t
    }

    public mutating func resume(at t: CMTime) {
        guard let s = openStart else { return }
        openStart = nil
        if t > s { intervals.append(CMTimeRange(start: s, end: t)) }
    }

    /// Output timestamp for capture time `t`, or nil when `t` falls inside a pause.
    public func adjusted(_ t: CMTime) -> CMTime? {
        if let s = openStart, t >= s { return nil }
        var offset = CMTime.zero
        for r in intervals {
            if t >= r.end { offset = offset + r.duration } else if t >= r.start { return nil }
        }
        return t - offset
    }

    /// Output end time when recording stops at capture time `t` (a paused recording ends where the pause began).
    public func endTime(stoppedAt t: CMTime) -> CMTime {
        let stop = openStart.map { min($0, t) } ?? t
        let offset = intervals.filter { $0.end <= stop }.reduce(CMTime.zero) { $0 + $1.duration }
        return stop - offset
    }
}
