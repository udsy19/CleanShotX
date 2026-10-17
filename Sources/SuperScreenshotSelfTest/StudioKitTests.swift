import Foundation
import CoreGraphics
import SuperScreenshotCore
import StudioKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
func registerStudioKitTests() {
    func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

    SelfTest.cases.append(("Studio.ClipTimeline", {
        let a = StudioClip(start: 0, duration: 4), b = StudioClip(start: 6, duration: 4)
        var tl = ClipTimeline(clips: [b, a], sourceDuration: 10)
        check(near(tl.outputDuration, 8), "output duration sums clips")
        check(near(tl.sourceTime(forOutput: 1), 1), "first clip maps 1:1")
        check(near(tl.sourceTime(forOutput: 5), 7), "second clip offset by the cut")
        check(tl.outputTime(forSource: 5) == nil, "cut source time has no output time")
        check(near(tl.outputTime(forSource: 7) ?? -1, 5), "output for source inverse")
        check(near(tl.outputTimeClamped(forSource: 5, preferLater: true), 4), "clamp forward to next clip")
        check(near(tl.outputTimeClamped(forSource: 5, preferLater: false), 4), "clamp back to previous clip end")
        let rightID = tl.split(atOutput: 2)
        check(rightID != nil && tl.clips.count == 3, "split creates a clip")
        check(near(tl.clips[0].duration, 2) && near(tl.clips[1].start, 2) && near(tl.clips[1].duration, 2), "split math")
        check(tl.split(atOutput: 2.05) == nil, "no split producing a sliver")
        check(near(tl.outputDuration, 8), "split keeps duration")
        if let id = rightID { check(tl.remove(id), "remove clip") }
        check(near(tl.outputDuration, 6) && near(tl.sourceTime(forOutput: 2.5), 6.5), "cut removes the range")
        tl.trimStart(tl.clips[1].id, to: 3)
        check(near(tl.clips[1].start, 3) && near(tl.clips[1].end, 10), "trim start extends into the gap")
        tl.trimStart(tl.clips[1].id, to: 0.5)
        check(near(tl.clips[1].start, 2), "trim start bounded by previous clip")
        tl.trimEnd(tl.clips[0].id, to: 9)
        check(near(tl.clips[0].end, 2), "trim end bounded by next clip")
        tl.trimEnd(tl.clips[1].id, to: 20)
        check(near(tl.clips[1].end, 10), "trim end bounded by recording")
        check(near(tl.nextEdge(after: 0.5), 2) && near(tl.previousEdge(before: 2), 0), "clip edges")
    }))

    SelfTest.cases.append(("Studio.TimelineGeometry", {
        let g = TimelineGeometry(pixelsPerSecond: 50, leftMargin: 16)
        check(near(g.x(for: 2), 116) && near(g.time(for: 116), 2), "time ↔ x")
        check(near(g.time(for: g.x(for: 3.37)), 3.37), "roundtrip")
        let fit = TimelineGeometry.fitting(duration: 10, width: 1032)
        check(near(fit.x(for: 10), 1016), "fit puts the end at the right margin")
        check(g.rulerStep * g.pixelsPerSecond >= 70, "readable ruler step")
        check(TimelineGeometry.clampScale(1e9) == TimelineGeometry.maxScale, "scale clamp")
        check(TimeFormat.string(65.34) == "1:05.3" && TimeFormat.string(65.34, tenths: false) == "1:05", "time format")
        check(TimeFormat.clock(8.9) == "00:08" && TimeFormat.clock(605) == "10:05", "transport clock format")
    }))

    SelfTest.cases.append(("Studio.LaneMath", {
        var zs = [ZoomSegment(start: 1, end: 3, level: 2), ZoomSegment(start: 5, end: 7, level: 2)]
        check(LaneMath.place(start: 2, end: 4, in: zs, duration: 10) == nil, "can't start inside a segment")
        let placed = LaneMath.place(start: 3.5, end: 6, in: zs, duration: 10)
        check(placed.map { near($0.0, 3.5) && near($0.1, 5) } ?? false, "placement clamps to next neighbour")
        LaneMath.move(zs[0].id, toStart: 4.5, in: &zs, duration: 10)
        check(near(zs[0].start, 3) && near(zs[0].end, 5), "move slides against neighbour")
        LaneMath.resizeEnd(zs[1].id, to: 20, in: &zs, duration: 10)
        check(near(zs[1].end, 10), "resize bounded by duration")
        LaneMath.resizeStart(zs[1].id, to: 9.9, in: &zs)
        check(near(zs[1].start, 10 - LaneMath.minimumDuration), "resize keeps minimum length")
        var ys = [ZoomSegment(start: 0, end: 4, level: 2.5, mode: .followCursor)]
        let id = LaneMath.split(at: 1.5, in: &ys) { $0.duplicated() }
        check(id != nil && ys.count == 2 && near(ys[0].end, 1.5) && near(ys[1].start, 1.5) && ys[1].level == 2.5 && ys[1].mode == .followCursor,
              "split zoom keeps properties")
        ys.applyLevelToAll(3)
        check(ys.allSatisfy { $0.level == 3 }, "apply level to all")
        var ds = [ZoomSegment(start: 1, end: 3, level: 2), ZoomSegment(start: 4, end: 9, level: 2)]
        let dup = LaneMath.duplicate(ds[0].id, in: &ds, duration: 10)
        check(dup != nil && ds.count == 3 && near(ds[1].start, 3) && near(ds[1].end, 4), "duplicate fits the gap after the zoom")
        check(LaneMath.duplicate(ds[2].id, in: &ds, duration: 9) == nil, "no room to duplicate at the end")
    }))

    SelfTest.cases.append(("Studio.Easing", {
        for e in ZoomEasing.allCases {
            check(near(Easing.apply(e, 0), 0) && near(Easing.apply(e, 1), 1), "\(e) endpoints")
            var last = -1.0, monotonic = true
            for i in 0...100 { let v = Easing.apply(e, Double(i) / 100); if v < last - 1e-12 { monotonic = false }; last = v }
            check(monotonic, "\(e) monotonic")
        }
        check(near(Easing.apply(.smooth, 0.5), 0.5), "ease-in-out symmetric")
        check(Easing.apply(.snappy, 0.3) > 0.3, "ease-out front-loaded")
    }))

    SelfTest.cases.append(("Studio.ZoomPlanner", {
        let seg = ZoomSegment(start: 2, end: 6, level: 2, focus: NPoint(x: 0.25, y: 0.25))
        let planner = ZoomPlanner(segments: [seg], animation: .smooth, easing: .smooth)
        let focus: (ZoomSegment, Double) -> NPoint = { s, _ in s.focus }
        check(planner.viewport(at: 1, focus: focus) == .identity, "no zoom before")
        let mid = planner.viewport(at: 4, focus: focus)
        check(near(mid.scale, 2, 1e-9) && near(Double(mid.rect.minX), 0) && near(Double(mid.rect.minY), 0), "full zoom, clamped inside canvas")
        let ramp = planner.viewport(at: 2 + ZoomAnimationStyle.smooth.duration / 2, focus: focus)
        check(ramp.scale > 1.2 && ramp.scale < 1.8, "half-way through zoom-in")
        check(near(planner.viewport(at: 6.01, focus: focus).scale, 1, 1e-9), "zoomed out after end")
        let instant = ZoomPlanner(segments: [seg], animation: .instant, easing: .linear)
        check(near(instant.viewport(at: 2.0001, focus: focus).scale, 2, 1e-9), "instant zoom")
        // Adjacent segments hand over without zooming out.
        let s2 = ZoomSegment(start: 6.2, end: 9, level: 3, focus: .center)
        let chained = ZoomPlanner(segments: [seg, s2], animation: .smooth, easing: .smooth)
        check(chained.viewport(at: 6.1, focus: focus).scale >= 2 - 1e-9, "merged gap holds the zoom")
        check(near(chained.viewport(at: 8, focus: focus).scale, 3, 1e-9), "second zoom level")
        let v = Viewport.make(scale: 4, center: NPoint(x: 0.99, y: 0.5))
        check(near(Double(v.rect.maxX), 1) && near(Double(v.rect.width), 0.25), "viewport clamped to the right edge")
    }))

    SelfTest.cases.append(("Studio.SmartZoom", {
        func click(_ t: Double, _ x: Double, _ y: Double) -> [ClickEvent] {
            [ClickEvent(t: t, p: NPoint(x: x, y: y), down: true), ClickEvent(t: t + 0.08, p: NPoint(x: x, y: y), down: false)]
        }
        let clicks = click(2, 0.2, 0.2) + click(2.8, 0.22, 0.21) + click(3.5, 0.21, 0.19) + click(12, 0.8, 0.8)
        let a = SmartZoomAnalyzer()
        let zooms = a.analyze(clicks: clicks, duration: 20)
        check(zooms.count == 2, "two clusters → two zooms (got \(zooms.count))")
        if zooms.count == 2 {
            check(near(zooms[0].start, 2 - a.clickLeadIn) && near(zooms[0].end, 3.5 + a.zoomTrailAfter), "lead-in and trail")
            check(zooms[0].level == a.highIntensityZoom, "tight repeated clicks zoom harder")
            check(zooms[0].focus.distance(to: NPoint(x: 0.21, y: 0.2)) < 0.02, "focus at the cluster centroid")
            check(zooms[1].level == a.normalZoom && zooms[1].duration >= a.minZoomDuration - 1e-9, "single click zoom has a minimum length")
            check(zooms[0].end <= zooms[1].start, "no overlap")
        }
        check(a.analyze(clicks: [], duration: 10).isEmpty, "no clicks, no zooms")
        let long = (0..<20).flatMap { click(1 + Double($0) * 0.9, 0.5, 0.5) }
        let chopped = a.analyze(clicks: long, duration: 40)
        check(chopped.allSatisfy { $0.duration <= a.maxZoomDuration + 1e-9 }, "max duration respected")
        let levels = a.analyze(clicks: click(5, 0.5, 0.5), duration: 10, defaultLevel: 3)
        check(levels.first?.level == 3, "default level override")
    }))

    SelfTest.cases.append(("Studio.CursorSmoothing", {
        // A straight line with deterministic jitter.
        var samples: [CursorSample] = []
        for i in 0..<240 {
            let t = Double(i) / 60
            let jitter = (i % 2 == 0 ? 1.0 : -1.0) * 0.01
            samples.append(CursorSample(t: t, p: NPoint(x: 0.1 + t * 0.1 + jitter, y: 0.5)))
        }
        let smooth = CursorTrack.smooth(samples, amount: 0.8)
        func roughness(_ s: [CursorSample]) -> Double {
            var total = 0.0
            for i in 1..<(s.count - 1) {
                let second: Double = s[i + 1].p.x - 2 * s[i].p.x + s[i - 1].p.x
                total += abs(second)
            }
            return total
        }
        check(roughness(smooth) < roughness(samples) * 0.25, "1€ filter removes jitter")
        check(CursorTrack.smooth(samples, amount: 0) == samples, "amount 0 is a passthrough")
        check(abs(smooth.last!.p.x - samples.last!.p.x) < 0.05, "smoothed path tracks the target")
        let p = CursorTrack.position(in: [CursorSample(t: 0, p: NPoint(x: 0, y: 0)), CursorSample(t: 1, p: NPoint(x: 1, y: 0.5))], at: 0.25)
        check(p.map { near($0.x, 0.25) && near($0.y, 0.125) } ?? false, "linear interpolation")

        var ev = StudioEvents()
        ev.cursor = [CursorSample(t: 0, p: .center), CursorSample(t: 0.5, p: NPoint(x: 0.6, y: 0.5)), CursorSample(t: 10, p: NPoint(x: 0.6, y: 0.5))]
        ev.clicks = [ClickEvent(t: 1, p: .center, down: true), ClickEvent(t: 1.2, p: .center, down: false)]
        ev.keys = [KeyEvent(t: 5, keyCode: 0, modifiers: 0, characters: "a")]
        let track = CursorTrack(events: ev, smoothing: 0)
        check(near(track.opacity(at: 1.5, hideWhenIdle: true, hideWhenTyping: false), 1), "visible right after activity")
        check(track.opacity(at: 4, hideWhenIdle: true, hideWhenTyping: false) < 0.01, "hidden when idle")
        check(near(track.opacity(at: 4, hideWhenIdle: false, hideWhenTyping: false), 1), "idle hiding off")
        check(track.opacity(at: 6, hideWhenIdle: false, hideWhenTyping: true) < 0.01, "hidden while typing")
        check(near(track.pressAmount(at: 1.1), 1) && near(track.pressAmount(at: 2), 0), "press state")
        check(track.ripples(at: 1.2).count == 1 && track.ripples(at: 2).isEmpty, "ripple lifetime")
    }))

    SelfTest.cases.append(("Studio.Keystrokes", {
        let cmd: UInt = 1 << 20, shift: UInt = 1 << 17
        check(KeystrokeFormatter.label(KeyEvent(t: 0, keyCode: 1, modifiers: cmd | shift, characters: "s")) == "⇧⌘S", "shortcut label")
        check(KeystrokeFormatter.label(KeyEvent(t: 0, keyCode: 36, modifiers: 0, characters: "\r")) == "↩", "special key")
        let keys = [KeyEvent(t: 1, keyCode: 4, modifiers: 0, characters: "h"), KeyEvent(t: 1.2, keyCode: 34, modifiers: 0, characters: "i"),
                    KeyEvent(t: 3, keyCode: 1, modifiers: cmd, characters: "s")]
        let shortcuts = KeystrokeTimeline(keys: keys, displayAll: false)
        check(shortcuts.entries.count == 1 && shortcuts.label(at: 3.1)?.text == "⌘S", "shortcuts only")
        let all = KeystrokeTimeline(keys: keys, displayAll: true)
        check(all.label(at: 1.1)?.text == "h" && all.label(at: 1.3)?.text == "hi", "typing accumulates")
        check(all.label(at: 2.9) == nil, "label disappears after hold")
    }))

    SelfTest.cases.append(("Studio.ProjectJSON", {
        var ev = StudioEvents()
        ev.cursor = [CursorSample(t: 0.016666, p: NPoint(x: 0.123456789, y: 0.5), kind: .iBeam)]
        ev.clicks = [ClickEvent(t: 1, p: .center, button: .right, down: true)]
        let info = RecordingInfo(pixelWidth: 3024, pixelHeight: 1964, scale: 2, duration: 12.5, fps: 60, hasCamera: true,
                                 hasSystemAudio: true, hasMicrophone: false, recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var p = StudioProject(title: "Demo", recording: info)
        p.zooms = [ZoomSegment(start: 1, end: 3, level: 2.2, mode: .followCursor, focus: NPoint(x: 0.3, y: 0.7))]
        p.cameraFullscreen = [TimeSegment(start: 4, end: 5)]
        p.style.background = .wallpaper(path: "/System/Library/Desktop Pictures/X.heic")
        p.style.cursor.style = .touch
        p.style.aspectRatio = .wide16x9
        let decoded = try? StudioPackage.decodeProject(StudioPackage.encode(p))
        check(decoded == p, "project.json roundtrip")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-selftest-\(UUID().uuidString).superscreenshotvideo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg = StudioPackage(url: dir)
        try? Data().write(to: pkg.screenURL)
        try? pkg.write(events: ev)
        try? pkg.write(project: p)
        let back = pkg.readEvents()
        check(back.cursor.first?.kind == .iBeam && near(back.cursor.first?.p.x ?? 0, 0.12346, 1e-5) && back.clicks == ev.clicks, "events.json roundtrip")
        var edited = p; edited.title = "Edited"
        pkg.autosave(project: edited)
        check((try? pkg.readProject()).map { $0.recovered && $0.project.title == "Edited" } ?? false, "autosave recovered")
        try? pkg.write(project: p)
        check((try? pkg.readProject()).map { !$0.recovered && $0.project == p } ?? false, "save clears autosave")
        try? FileManager.default.removeItem(at: dir)
    }))

    SelfTest.cases.append(("Studio.CanvasLayout", {
        var style = StudioStyle()
        style.padding = 0.1
        let src = CGSize(width: 2000, height: 1000)
        let base = CanvasLayout.baseCanvasSize(sourceSize: src, style: style)
        check(base == src, "auto aspect keeps the recording size")
        let l = CanvasLayout(sourceSize: src, style: style, canvasSize: base)
        check(near(Double(l.screenRect.minY), 100) && near(Double(l.screenRect.height), 800) && near(Double(l.screenRect.midX), 1000), "padding fits the screen")
        let pt = l.canvasPoint(NPoint(x: 0, y: 0))
        check(near(Double(pt.x), Double(l.screenRect.minX)) && near(Double(pt.y), Double(l.screenRect.maxY)), "top-left maps to the screen's top-left")
        style.aspectRatio = .square
        check(CanvasLayout.baseCanvasSize(sourceSize: src, style: style) == CGSize(width: 2000, height: 2000), "aspect ratio extends canvas")
        check(CanvasLayout.scaled(CGSize(width: 1920, height: 1080), shortSide: 720) == CGSize(width: 1280, height: 720), "resolution preset")
        let z = l.zoomTransform(Viewport.make(scale: 2, center: .center))
        let c = CGPoint(x: 1000, y: 500).applying(z)
        check(near(Double(c.x), 1000) && near(Double(c.y), 500), "centered zoom keeps the center")
    }))

    SelfTest.cases.append(("Studio.ExportEstimate", {
        var s = ExportSettings()
        let base = CGSize(width: 3024, height: 1964)
        s.resolution = .fhd1080
        check(s.outputSize(base: base).height == 1080, "1080p preset")
        s.quality = 0.2
        let low = EncoderEstimate.estimatedBytes(settings: s, base: base, duration: 60, hasAudio: true)
        s.quality = 1
        let high = EncoderEstimate.estimatedBytes(settings: s, base: base, duration: 60, hasAudio: true)
        check(high > low && low > 0, "quality increases size")
        s.format = .hevc
        check(EncoderEstimate.estimatedBytes(settings: s, base: base, duration: 60, hasAudio: true) < high, "HEVC is smaller")
        s.format = .gif; s.resolution = .original
        check(s.outputSize(base: base).height <= 720 && s.effectiveFPS == s.gifFPS, "GIF caps size and uses the GIF frame rate")
        s = ExportSettings(); s.resolution = .original
        check(s.outputSize(base: CGSize(width: 6000, height: 3000)).width <= 4096, "H.264 size limit")
        let opts = ExportSettings.Resolution.options(for: CGSize(width: 1920, height: 1080))
        check(opts.first == .original && !opts.contains(.fhd1080) && !opts.contains(.uhd4k) && opts.contains(.p240), "no upscaling presets")
        check(ExportSettings.qualityTitle(0.1) == "Very low" && ExportSettings.qualityTitle(0.9) == "High", "quality labels")
    }))

    SelfTest.cases.append(("Studio.StyleCompatibility", {
        // A project.json style written before the 3×3 grids, click styles and per-source audio toggles existed.
        let legacy = """
        {"background":{"gradient":{"_0":2}},"padding":0.1,"cornerRadius":20,"shadow":0.5,"inset":0,"aspectRatio":"wide16x9",
         "cursor":{"show":true,"size":2,"smoothing":0.6,"hideWhenIdle":false,"hideWhenTyping":false,"clickEffect":"ripple",
                   "pressEffect":true,"style":"macOS","rippleColor":{"r":1,"g":1,"b":1,"a":0.9}},
         "zoom":{"defaultLevel":2,"autoZoom":true,"followCursorByDefault":false,"animation":"smooth","easing":"smooth","motionBlur":0},
         "camera":{"show":true,"position":"topLeft","size":0.24,"shape":"circle","shrinkOnZoom":true,"flip":true},
         "keystrokes":{"show":true,"size":1,"position":"top","displayAll":false},
         "audio":{"microphoneVolume":0.5,"systemVolume":1,"muted":true}}
        """
        let style = try? JSONDecoder().decode(StudioStyle.self, from: Data(legacy.utf8))
        check(style != nil, "legacy style decodes")
        if let style {
            check(style.camera.position == .topLeft && style.keystrokes.position == .top, "old positions map onto the grid")
            check(style.keystrokes.style == .dark && style.cursor.clickStyle == .outline, "new fields get defaults")
            check(!style.audio.includeMicrophone && !style.audio.includeSystemAudio && near(style.audio.microphoneVolume, 0.5), "muted → excluded")
            check(style.aspectRatio == .wide16x9 && style.background == .gradient(.sunrise), "unchanged fields survive")
        }
        let partial = try? JSONDecoder().decode(StudioStyle.self, from: Data(#"{"padding":0.2,"aspectRatio":"bogus"}"#.utf8))
        check(partial.map { near($0.padding, 0.2) && $0.aspectRatio == .auto } ?? false, "unknown values fall back")
        let g = GridPosition.bottomRight.origin(of: CGSize(width: 10, height: 10), in: CGSize(width: 100, height: 50), margin: 5)
        check(g == CGPoint(x: 85, y: 5), "bottom-right origin (bottom-left space)")
        let c = GridPosition.top.origin(of: CGSize(width: 10, height: 10), in: CGSize(width: 100, height: 50), margin: 5)
        check(c == CGPoint(x: 45, y: 35), "top-centre origin")
        check(ClickColor.nearest(RGBAColor(r: 0.05, g: 0.5, b: 0.98)) == .blue, "nearest named click colour")
        var cur = CursorSettings(); cur.smoothing = CursorSettings.smoothSmoothing
        check(cur.isSmoothMotion, "smooth motion preset")
        var z = ZoomSettings(); z.setDynamic(true)
        check(z.isDynamic && z.animation == .quick, "dynamic zoom preset")
        z.setDynamic(false)
        check(!z.isDynamic, "smooth zoom preset")
    }))

    SelfTest.cases.append(("Studio.RecordingClock", {
        let c = RecordingClock()
        check(c.mediaTime(forHost: 5) == nil, "nothing before start")
        c.start(atHost: 100)
        check(near(c.mediaTime(forHost: 101.5) ?? -1, 1.5), "running")
        c.pause(atHost: 102)
        check(c.mediaTime(forHost: 103) == nil && c.isPaused, "paused drops samples")
        c.resume(atHost: 105)
        check(near(c.mediaTime(forHost: 106) ?? -1, 3), "pause removed from timeline")
        check(near(c.mediaTime(forHost: 101) ?? -1, 1), "before pause unaffected")
        c.stop(atHost: 110)
        check(c.mediaTime(forHost: 111) == nil && near(c.elapsed(), 7), "stopped")
    }))
}
