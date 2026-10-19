import AppKit
import AVFoundation
import ImageIO
import SuperScreenshotCore
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

    SelfTest.cases.append(("RecordingKit.pauseTimeline", {
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1000) }
        var p = PauseTimeline()
        check(p.adjusted(t(5)) == t(5), "no pauses: identity")
        p.pause(at: t(10))
        check(p.isPaused, "paused")
        check(p.adjusted(t(9.9)) == t(9.9), "sample captured before pause kept even if it arrives later")
        check(p.adjusted(t(10.5)) == nil, "sample during open pause dropped")
        check(p.endTime(stoppedAt: t(20)) == t(10), "stopping while paused ends where the pause began")
        p.resume(at: t(14))
        check(!p.isPaused, "resumed")
        check(p.adjusted(t(12)) == nil, "sample inside a closed pause dropped")
        check(p.adjusted(t(15)) == t(11), "after resume shifted by pause length: \(String(describing: p.adjusted(t(15))?.seconds))")
        p.pause(at: t(20)); p.resume(at: t(21))
        check(p.adjusted(t(22)) == t(17), "two pauses accumulate")
        check(p.endTime(stoppedAt: t(30)) == t(25), "end time excludes pauses")
        p.pause(at: t(40)); p.pause(at: t(41))
        p.resume(at: t(40))
        check(p.adjusted(t(45)) == t(40), "double pause ignored; zero-length resume adds nothing")
    }))

    SelfTest.cases.append(("RecordingKit.areaGeometry", {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let r = RecordingMath.resized(CGRect(x: 100, y: 100, width: 200, height: 100), to: CGSize(width: 400, height: 300), within: bounds)
        check(r == CGRect(x: 0, y: 0, width: 400, height: 300), "resize keeps centre but stays inside: \(r)")
        let big = RecordingMath.resized(CGRect(x: 0, y: 0, width: 10, height: 10), to: CGSize(width: 5000, height: 5000), within: bounds)
        check(big == bounds, "resize clamps to bounds: \(big)")
        let c = RecordingMath.constrained(CGRect(x: 0, y: 0, width: 800, height: 800), toAspect: 16.0 / 9, within: bounds)
        check(c.width == 800 && c.height == 450 && c.midY == 400, "16:9 fits inside and stays centred: \(c)")
        let tall = RecordingMath.constrained(CGRect(x: 0, y: 0, width: 400, height: 200), toAspect: 1, within: bounds)
        check(tall.size == CGSize(width: 200, height: 200), "1:1 from wide rect: \(tall)")
        let panel = CGSize(width: 227, height: 201)
        let inside = RecordingMath.setupPanelOrigin(panel: panel, area: CGRect(x: 100, y: 100, width: 600, height: 500), bounds: bounds)
        check(inside == CGPoint(x: 287, y: 250), "panel centred in a large area: \(inside)")
        let below = RecordingMath.setupPanelOrigin(panel: panel, area: CGRect(x: 400, y: 500, width: 100, height: 80), bounds: bounds)
        check(below.y + panel.height <= 500 - 12 + 0.5, "panel below a small area: \(below)")
        let clamped = RecordingMath.setupPanelOrigin(panel: panel, area: CGRect(x: 0, y: 0, width: 50, height: 50), bounds: bounds)
        check(clamped.x >= 8 && clamped.y >= 8, "panel stays on screen: \(clamped)")
    }))

    SelfTest.cases.append(("RecordingKit.exportResolutions", {
        let source = CGSize(width: 2880, height: 1800)
        let options = RecordingMath.exportOptions(for: source)
        check(options.first?.shortSide == 0 && options.first?.size.width == 2880, "original first")
        check(!options.contains { $0.title == "4k" }, "no upscaling preset above the source")
        if let p1080 = options.first(where: { $0.title == "1080p" }) {
            check(p1080.size.height == 1080 && p1080.size.width == 1728, "1080p keeps aspect: \(p1080.size)")
        } else { check(false, "1080p offered") }
        check(options.allSatisfy { $0.size.width % 2 == 0 && $0.size.height % 2 == 0 }, "even output sizes")
        check(RecordingMath.exportScale(source: source, shortSide: 0) == 1, "0 = original")
        check(RecordingMath.exportScale(source: CGSize(width: 640, height: 480), shortSide: 1080) == 1, "never upscales")
        check(abs(RecordingMath.exportScale(source: CGSize(width: 1080, height: 1920), shortSide: 720) - 720.0 / 1080) < 1e-9, "portrait uses short side")
    }))

    SelfTest.cases.append(("RecordingKit.gifFrames", {
        let delays = [0.1, 0.2, 0.1]
        check(RecordingMath.frameIndex(at: 0, delays: delays) == 0, "t=0 first frame")
        check(RecordingMath.frameIndex(at: 0.15, delays: delays) == 1, "inside second frame")
        check(RecordingMath.frameIndex(at: 0.3, delays: delays) == 2, "boundary belongs to the next frame")
        check(RecordingMath.frameIndex(at: 10, delays: delays) == 2, "clamped to last")
        check(RecordingMath.frameIndex(at: 1, delays: []) == 0, "empty")
        check(StreamingGIFWriter.delayCentiseconds(0.066) == 7 && StreamingGIFWriter.delayCentiseconds(0) == 2, "centiseconds ≥ 2")
    }))

    SelfTest.cases.append(("RecordingKit.streamingGIF", {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rk-selftest-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        func frame(_ i: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(i) / 3, green: 0.4, blue: 1 - CGFloat(i) / 3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: i * 10, y: 10, width: 12, height: 12))
            return ctx.makeImage()!
        }
        do {
            let writer = try StreamingGIFWriter(url: url)
            for (i, d) in [0.1, 0.05, 0.5].enumerated() { try writer.add(frame(i), delay: d) }
            try writer.finish()
            check(writer.size == CGSize(width: 64, height: 40), "canvas size from first frame")
        } catch { check(false, "writer threw \(error)"); return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { check(false, "readable GIF"); return }
        check(CGImageSourceGetCount(src) == 3, "3 frames, got \(CGImageSourceGetCount(src))")
        let delays = (0..<3).map { i -> Double in
            let gif = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? -1
        }
        check(zip(delays, [0.1, 0.05, 0.5]).allSatisfy { abs($0 - $1) < 0.001 }, "delays preserved: \(delays)")
        let loop = ((CGImageSourceCopyProperties(src, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        check(loop == 0, "loops forever: \(String(describing: loop))")
        let last = CGImageSourceCreateImageAtIndex(src, 2, nil)
        check(last?.width == 64 && last?.height == 40, "frames decode at full size")
    }))

    // MARK: Export safety (synthetic videos only; the screen is never captured)

    SelfTest.cases.append(("RecordingKit.exportTrim", {
        let dir = TestDir.make("rk-export")
        defer { dir.remove() }
        let source = dir.url.appendingPathComponent("source.mov")
        guard SyntheticVideo.write(to: source, seconds: 3) else { check(false, "synthetic video"); return }
        let before = fingerprint(source)
        let out = dir.url.appendingPathComponent("trimmed.mov")
        let r1 = blocking { try await VideoExporter.export(source: source, options: passthrough(0.5, 1.5), to: out) { _ in } }
        check((try? r1.get()) != nil, "passthrough trim succeeds: \(r1)")
        check(abs(duration(out) - 1) < 0.1, "trimmed to 1 s: \(duration(out))")
        let out2 = dir.url.appendingPathComponent("small.mp4")
        let small: VideoExportOptions = { var o = reencode(0, 2); o.fileType = .mp4; return o }()
        let r2 = blocking { try await VideoExporter.export(source: source, options: small, to: out2) { _ in } }
        check((try? r2.get()).map { $0.width == 160 && $0.height == 100 } ?? false, "re-encode halves the size: \(r2)")
        check(abs(duration(out2) - 2) < 0.1, "re-encoded 2 s: \(duration(out2))")
        check(fingerprint(source) == before, "source untouched after exports")
    }))

    SelfTest.cases.append(("RecordingKit.exportOverSource", {
        let dir = TestDir.make("rk-export-over")
        defer { dir.remove() }
        let source = dir.url.appendingPathComponent("clip.mov")
        guard SyntheticVideo.write(to: source, seconds: 3) else { check(false, "synthetic video"); return }
        let link = dir.url.appendingPathComponent("alias.mov")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        check(VideoExporter.isSameFile(source, link) && VideoExporter.isSameFile(source, URL(fileURLWithPath: source.path)), "same-file detection")
        check(!VideoExporter.isSameFile(source, dir.url.appendingPathComponent("other.mov")), "different files")
        let temps = tempFileCount()
        // Exporting onto the source itself: the file must be replaced only by a complete export.
        let r = blocking { try await VideoExporter.export(source: source, options: passthrough(1, 2), to: source) { _ in } }
        check((try? r.get()) != nil, "export over the source succeeds: \(r)")
        check(abs(duration(source) - 1) < 0.1, "source now holds the 1 s trim: \(duration(source))")
        check(tempFileCount() == temps, "no temporary file left behind")
        // A failing export over the source (empty trim range → no video) leaves the source exactly as it was.
        let before = fingerprint(source)
        let bad = blocking { try await VideoExporter.export(source: source, options: passthrough(5, 6), to: source) { _ in } }
        check((try? bad.get()) == nil, "empty range fails")
        check(fingerprint(source) == before && abs(duration(source) - 1) < 0.1, "failed export never touches the source")
        check(tempFileCount() == temps, "no temporary file left behind after failure")
    }))

    SelfTest.cases.append(("RecordingKit.exportCancel", {
        let dir = TestDir.make("rk-export-cancel")
        defer { dir.remove() }
        let source = dir.url.appendingPathComponent("long.mov")
        guard SyntheticVideo.write(to: source, seconds: 10, size: CGSize(width: 640, height: 400)) else { check(false, "synthetic video"); return }
        let before = fingerprint(source)
        let out = dir.url.appendingPathComponent("out.mov")
        let slow: VideoExportOptions = { var o = reencode(0, 10); o.scale = 1; return o }()
        let gate = CancelGate()
        let task = Task.detached { try await VideoExporter.export(source: source, options: slow, to: out) { p in if p > 0 { gate.cancel() } } }
        gate.attach(task)
        let r = blocking { try await task.value }
        if case .failure(VideoExportError.cancelled) = r {} else { check(false, "cancel mid-way throws cancelled, got \(r)") }
        check(!FileManager.default.fileExists(atPath: out.path), "partial output removed after cancel")
        check(fingerprint(source) == before, "source untouched after cancel")
        // A passthrough export whose task is cancelled before it starts also leaves nothing behind.
        let pre = Task.detached { try await VideoExporter.export(source: source, options: passthrough(0, 10), to: out) { _ in } }
        pre.cancel()
        let r2 = blocking { try await pre.value }
        check((try? r2.get()) == nil && !FileManager.default.fileExists(atPath: out.path), "pre-cancelled passthrough writes nothing: \(r2)")
        // The same source exports fine afterwards (a second export can start).
        let r3 = blocking { try await VideoExporter.export(source: source, options: passthrough(0, 1), to: out) { _ in } }
        check((try? r3.get()) != nil && FileManager.default.fileExists(atPath: out.path), "export after cancel works: \(r3)")
    }))

    SelfTest.cases.append(("RecordingKit.exportFailure", {
        let dir = TestDir.make("rk-export-fail")
        defer { dir.remove() }
        let fm = FileManager.default
        let source = dir.url.appendingPathComponent("source.mov")
        guard SyntheticVideo.write(to: source, seconds: 2) else { check(false, "synthetic video"); return }
        let before = fingerprint(source)
        let locked = dir.url.appendingPathComponent("locked", isDirectory: true)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }
        for (name, options) in [("passthrough", passthrough(0, 1)), ("re-encode", reencode(0, 1))] {
            let out = locked.appendingPathComponent("out.mov")
            let r = blocking { try await VideoExporter.export(source: source, options: options, to: out) { _ in } }
            if case .failure(let e) = r { check(!e.localizedDescription.isEmpty, "\(name) into unwritable folder has a message") }
            else { check(false, "\(name) into unwritable folder fails") }
            check(!fm.fileExists(atPath: out.path), "\(name): nothing written into the unwritable folder")
        }
        let asDir = dir.url.appendingPathComponent("taken.mov", isDirectory: true)
        try? fm.createDirectory(at: asDir, withIntermediateDirectories: true)
        try? Data([1]).write(to: asDir.appendingPathComponent("keep"))
        let rd = blocking { try await VideoExporter.export(source: source, options: passthrough(0, 1), to: asDir) { _ in } }
        check((try? rd.get()) == nil && rd.failureDescription.contains("folder"), "destination that is a folder fails: \(rd)")
        check(fm.fileExists(atPath: asDir.appendingPathComponent("keep").path), "the folder in the way is left alone")
        let rgd = blocking { try await GIFEncoder.convert(video: source, to: asDir, fps: 10, maxWidth: 320) { _ in } }
        check((try? rgd.get()) == nil && fm.fileExists(atPath: asDir.appendingPathComponent("keep").path), "GIF onto a folder fails and leaves it alone: \(rgd)")
        check(fingerprint(source) == before, "source untouched after failures")
        let missing = dir.url.appendingPathComponent("gone.mov")
        let rm = blocking { try await VideoExporter.export(source: missing, options: passthrough(0, 1), to: dir.url.appendingPathComponent("x.mov")) { _ in } }
        if case .failure(VideoExportError.missingSource) = rm { check(rm.failureDescription.contains("moved or deleted"), "missing source message") }
        else { check(false, "missing source → clear error, got \(rm)") }
        let empty = dir.url.appendingPathComponent("empty.mov")
        try? Data().write(to: empty)
        let re = blocking { try await VideoExporter.export(source: empty, options: passthrough(0, 1), to: dir.url.appendingPathComponent("y.mov")) { _ in } }
        check((try? re.get()) == nil && !re.failureDescription.isEmpty, "zero-length source fails with a message, no crash: \(re)")
        let rg = blocking { try await GIFEncoder.convert(video: missing, to: dir.url.appendingPathComponent("z.gif"), fps: 10, maxWidth: 320) { _ in } }
        if case .failure(GIFError.missingSource) = rg {} else { check(false, "GIF from a missing source → clear error, got \(rg)") }
    }))

    SelfTest.cases.append(("RecordingKit.gifConvertStreams", {
        let dir = TestDir.make("rk-gif")
        defer { dir.remove() }
        let fm = FileManager.default
        let source = dir.url.appendingPathComponent("source.mov")
        guard SyntheticVideo.write(to: source, seconds: 20, size: CGSize(width: 640, height: 400)) else { check(false, "synthetic video"); return }
        func convert(_ seconds: Double, to out: URL) -> Result<CGSize, Error> {
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
            return blocking { try await GIFEncoder.convert(video: source, to: out, timeRange: range, fps: 15, maxWidth: 640) { _ in } }
        }
        // Warm up (decoder, ImageIO, colour management), then measure a 300-frame conversion: held frames
        // would cost 640×400×4 B × 300 ≈ 300 MB, so growth well under that proves frames are streamed.
        let warm = convert(2, to: dir.url.appendingPathComponent("warm.gif"))
        check((try? warm.get()) != nil, "warm-up conversion: \(warm)")
        let rssBefore = residentMemoryBytes()
        let out = dir.url.appendingPathComponent("long.gif")
        let r = convert(20, to: out)
        let growth = Double(residentMemoryBytes()) - Double(rssBefore)
        check((try? r.get()).map { $0.width == 640 } ?? false, "20 s conversion: \(r)")
        if let src = CGImageSourceCreateWithURL(out as CFURL, nil) { check(CGImageSourceGetCount(src) == 300, "300 frames, got \(CGImageSourceGetCount(src))") }
        else { check(false, "readable GIF") }
        check(growth < 100 * 1024 * 1024, "memory stays flat while converting (grew \(Int(growth / 1_048_576)) MB)")
        // Cancellation removes the partial GIF; the source is untouched.
        let before = fingerprint(source)
        let partial = dir.url.appendingPathComponent("partial.gif")
        let gate = CancelGate()
        let task = Task.detached {
            try await GIFEncoder.convert(video: source, to: partial, fps: 15, maxWidth: 640) { p in if p > 0.1 { gate.cancel() } }
        }
        gate.attach(task)
        let rc = blocking { try await task.value }
        if case .failure(GIFError.cancelled) = rc {} else { check(false, "cancelled conversion throws cancelled, got \(rc)") }
        check(!fm.fileExists(atPath: partial.path), "partial GIF removed after cancel")
        check(fingerprint(source) == before, "source untouched")
        // Unwritable destination: clear system error, nothing left behind.
        let locked = dir.url.appendingPathComponent("locked", isDirectory: true)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }
        let rl = convert(1, to: locked.appendingPathComponent("no.gif"))
        check((try? rl.get()) == nil && rl.failureDescription.localizedCaseInsensitiveContains("permission"), "unwritable folder → permission error: \(rl)")
        check(!fm.fileExists(atPath: locked.appendingPathComponent("no.gif").path), "nothing written into the unwritable folder")
    }))
}

// MARK: - Shared fixtures

private func passthrough(_ s: Double, _ e: Double) -> VideoExportOptions {
    VideoExportOptions(timeRange: CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), end: CMTime(seconds: e, preferredTimescale: 600)),
                       includeAudio: true, volume: 1, quality: .original, scale: 1, fileType: .mov)
}
private func reencode(_ s: Double, _ e: Double) -> VideoExportOptions {
    var o = passthrough(s, e); o.quality = .high; o.scale = 0.5; return o
}
private func duration(_ url: URL) -> Double {
    (try? blocking { try await AVURLAsset(url: url).load(.duration).seconds }.get()) ?? -1
}
/// Size + modification date: enough to prove a file was not rewritten.
private func fingerprint(_ url: URL) -> (Int, Date?) {
    let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return (v?.fileSize ?? -1, v?.contentModificationDate)
}
private func tempFileCount() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.temporary.path).count) ?? -1 }

extension Result {
    var failureDescription: String { if case .failure(let e) = self { return e.localizedDescription }; return "" }
}

/// A throw-away folder under the system temporary directory.
struct TestDir {
    let url: URL
    static func make(_ name: String) -> TestDir {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("superscreenshot-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return TestDir(url: url)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Cancels a task from a progress callback that may fire before the task handle exists.
final class CancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<CGSize, Error>?
    private var wanted = false
    func attach(_ t: Task<CGSize, Error>) { lock.lock(); task = t; let w = wanted; lock.unlock(); if w { t.cancel() } }
    func cancel() { lock.lock(); wanted = true; let t = task; lock.unlock(); t?.cancel() }
}

/// Solid-colour H.264 test videos written with AVAssetWriter; never records the screen or audio.
enum SyntheticVideo {
    @discardableResult
    static func write(to url: URL, seconds: Double, fps: Int = 30, size: CGSize = CGSize(width: 320, height: 200)) -> Bool {
        let (w, h) = (Int(size.width), Int(size.height))
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let count = Int(seconds * Double(fps))
        for i in 0..<count {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return false }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                // BGRA; the colour drifts per frame so the encoder has real changes to encode.
                var pixel: UInt32 = 0xFF00_0000 | UInt32((i * 7) % 256) << 16 | UInt32((i * 3) % 256) << 8 | UInt32(255 - i % 256)
                memset_pattern4(base, &pixel, CVPixelBufferGetBytesPerRow(pb) * h)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))) else { return false }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}
