import Foundation
import CoreGraphics
import AppKit
import ShotcraftCore

/// Pure, side-effect-free helpers for the recording pipeline (covered by ShotcraftSelfTest).
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
