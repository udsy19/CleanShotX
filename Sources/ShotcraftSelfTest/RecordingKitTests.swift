import AppKit
import ShotcraftCore
import RecordingKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
func registerRecordingKitTests() {
    SelfTest.cases.append(("RecordingKit.formatElapsed", {
        check(RecordingMath.formatElapsed(0) == "0:00", "zero")
        check(RecordingMath.formatElapsed(7.9) == "0:07", "rounds down")
        check(RecordingMath.formatElapsed(62) == "1:02", "minutes")
        check(RecordingMath.formatElapsed(3723) == "1:02:03", "hours")
        check(RecordingMath.formatElapsed(-5) == "0:00", "negative clamps")
    }))

    SelfTest.cases.append(("RecordingKit.evenPixelSize", {
        let a = RecordingMath.evenPixelSize(points: CGSize(width: 101, height: 57), scale: 1)
        check(a.width == 100 && a.height == 56, "odd 1x dims round down to even")
        let b = RecordingMath.evenPixelSize(points: CGSize(width: 100.5, height: 50.25), scale: 2)
        check(b.width == 200 && b.height == 100, "retina dims even: \(b)")
        let c = RecordingMath.evenPixelSize(points: CGSize(width: 0.4, height: 1), scale: 1)
        check(c.width == 2 && c.height == 2, "minimum 2x2")
        let d = RecordingMath.evenPixelSize(points: CGSize(width: 333, height: 333), scale: 1.5)
        check(d.width % 2 == 0 && d.height % 2 == 0 && d.width == 498, "fractional scale even: \(d)")
    }))

    SelfTest.cases.append(("RecordingKit.bitrateAndSize", {
        let low = RecordingMath.videoBitrate(width: 1920, height: 1080, fps: 30, quality: .low)
        let high = RecordingMath.videoBitrate(width: 1920, height: 1080, fps: 30, quality: .high)
        let high60 = RecordingMath.videoBitrate(width: 1920, height: 1080, fps: 60, quality: .high)
        check(low < high && high < high60, "bitrate grows with quality and fps")
        check(high60 < high * 2, "fps scaling is sublinear")
        check(RecordingMath.videoBitrate(width: 2, height: 2, fps: 1, quality: .low) == 500_000, "floor 0.5 Mbit/s")
        check(RecordingMath.videoBitrate(width: 8192, height: 8192, fps: 120, quality: .original) == 120_000_000, "ceiling 120 Mbit/s")
        let size = RecordingMath.estimatedFileSize(videoBitrate: 8_000_000, audioBitrates: [128_000, 64_000], duration: 10)
        let expected = Int64((Double(8_192_000) * 10 / 8 * 1.015).rounded())
        check(size == expected, "estimated size \(size) == \(expected)")
        check(RecordingMath.estimatedFileSize(videoBitrate: 1_000_000, audioBitrates: [], duration: -1) == 0, "negative duration")
        check(RecordingMath.codec(for: .high, width: 1920, height: 1080) == .h264, "h264 default")
        check(RecordingMath.codec(for: .original, width: 1920, height: 1080) == .hevc, "hevc for original")
        check(RecordingMath.codec(for: .low, width: 5120, height: 2880) == .hevc, "hevc above H.264 limit")
    }))

    SelfTest.cases.append(("RecordingKit.gifTiming", {
        let times = RecordingMath.gifFrameTimes(duration: 1, fps: 15)
        check(times.count == 15, "15 frames for 1s @15fps, got \(times.count)")
        check(times.first == 0 && (times.last ?? 1) < 1, "times within [0, duration)")
        check(RecordingMath.gifFrameTimes(duration: 0, fps: 15).isEmpty, "no frames for empty video")
        check(RecordingMath.gifFrameTimes(duration: 0.01, fps: 10).count == 1, "short video still yields one frame")
        let delays = RecordingMath.gifFrameDelays(count: 15, fps: 15)
        check(delays.allSatisfy { abs($0 * 100 - ($0 * 100).rounded()) < 1e-9 }, "centisecond quantized")
        check(abs(delays.reduce(0, +) - 1) <= 0.005, "total ≈ 1s, got \(delays.reduce(0, +))")
        check(Set(delays).isSubset(of: [0.06, 0.07]), "delays alternate 6/7 cs: \(Set(delays))")
        check(RecordingMath.gifFrameDelays(count: 3, fps: 100).allSatisfy { $0 >= 0.02 }, "min 2 cs")
        check(RecordingMath.clampedGIFFPS(60) == 50 && RecordingMath.clampedGIFFPS(0) == 1, "fps clamp")
        let fit = RecordingMath.fitted(CGSize(width: 2000, height: 1000), maxWidth: 1280)
        check(fit == CGSize(width: 1280, height: 640), "fit to max width")
        check(RecordingMath.fitted(CGSize(width: 800, height: 600), maxWidth: 1280) == CGSize(width: 800, height: 600), "no upscale")
        check(RecordingMath.fitted(CGSize(width: 4000, height: 10), maxWidth: 0).width == 4000, "0 = unlimited")
    }))

    SelfTest.cases.append(("RecordingKit.clockAndKeys", {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        var clock = RecordingClock()
        clock.start(at: t0)
        clock.pause(at: t0.addingTimeInterval(10))
        check(clock.elapsed(at: t0.addingTimeInterval(100)) == 10, "paused clock stands still")
        clock.resume(at: t0.addingTimeInterval(20))
        check(clock.elapsed(at: t0.addingTimeInterval(25)) == 15, "resumed clock excludes pause")
        clock.start(at: t0.addingTimeInterval(30))
        check(clock.elapsed(at: t0.addingTimeInterval(31)) == 1, "restart resets")
        check(RecordingMath.keystrokeLabel(modifiers: [.command, .shift], key: "K") == "⇧⌘K", "modifier order")
        check(RecordingMath.keystrokeLabel(modifiers: [.control, .option, .shift, .command], key: "5") == "⌃⌥⇧⌘5", "all modifiers")
        check(RecordingMath.isShortcut([.command]) && !RecordingMath.isShortcut([.shift]), "shift alone is typing")
        check(RecordingMath.isDiskNearlyFull(availableBytes: 100 * 1024 * 1024), "100 MB is nearly full")
        check(!RecordingMath.isDiskNearlyFull(availableBytes: 10 * 1024 * 1024 * 1024), "10 GB is fine")
    }))
}
