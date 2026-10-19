import Foundation
import CoreGraphics
import SuperScreenshotCore
import AnnotateKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
func registerAnnotateKitTests() {
    func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.01) -> Bool { abs(a - b) <= eps }
    func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 0.01) -> Bool { near(a.x, b.x, eps) && near(a.y, b.y, eps) }
    func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 0.01) -> Bool {
        near(a.minX, b.minX, eps) && near(a.minY, b.minY, eps) && near(a.width, b.width, eps) && near(a.height, b.height, eps)
    }

    /// Opaque RGBA test image (w×h pixels) with a red top-left pixel.
    func testImage(_ w: Int, _ h: Int, transparentMargin: Int = 0) -> CGImage {
        let ctx = ImageTools.context(width: w, height: h)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        let m = CGFloat(transparentMargin)
        ctx.fill(CGRect(x: m, y: m, width: CGFloat(w) - 2 * m, height: CGFloat(h) - 2 * m))
        if transparentMargin == 0 {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h - 1, width: 1, height: 1))  // CG origin is bottom-left → top-left pixel
        }
        return ctx.makeImage()!
    }

    SelfTest.cases.append(("Annotate.Geometry", {
        check(Geo.rect(CGPoint(x: 10, y: 20), CGPoint(x: 2, y: 4)) == CGRect(x: 2, y: 4, width: 8, height: 16), "rect from points standardizes")
        let c = Geo.constrainAngle(CGPoint(x: 10, y: 9), from: .zero)
        check(near(c.x, c.y), "⇧ snaps a near-diagonal to 45°")
        let h = Geo.constrainAngle(CGPoint(x: 10, y: 1), from: .zero)
        check(near(h.y, 0) && near(h.x, hypot(10, 1)), "⇧ snaps a near-horizontal to 0° keeping length")
        let (s1, e1) = Geo.dragRect(from: .zero, to: CGPoint(x: 10, y: -4), square: true, fromCenter: false)
        check(s1 == .zero && e1 == CGPoint(x: 10, y: -10), "square keeps drag direction")
        let (s2, e2) = Geo.dragRect(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 8, y: 9), square: false, fromCenter: true)
        check(s2 == CGPoint(x: 2, y: 1) && e2 == CGPoint(x: 8, y: 9), "⌥ draws from centre")
        check(near(Geo.distance(CGPoint(x: 5, y: 3), segment: .zero, CGPoint(x: 10, y: 0)), 3), "point-segment distance")
        check(near(Geo.distance(CGPoint(x: 13, y: 4), segment: .zero, CGPoint(x: 10, y: 0)), 5), "distance clamps to the endpoint")
        let r = CGRect(x: 0, y: 0, width: 100, height: 50)
        check(near(Geo.resize(r, handle: .bottomRight, to: CGPoint(x: 120, y: 80), keepAspect: false, fromCenter: false),
                   CGRect(x: 0, y: 0, width: 120, height: 80)), "free corner resize")
        check(near(Geo.resize(r, handle: .bottomRight, to: CGPoint(x: 200, y: 60), keepAspect: true, fromCenter: false),
                   CGRect(x: 0, y: 0, width: 200, height: 100)), "aspect-locked corner resize")
        check(near(Geo.resize(r, handle: .right, to: CGPoint(x: -20, y: 25), keepAspect: false, fromCenter: false),
                   CGRect(x: -20, y: 0, width: 20, height: 50)), "dragging past the opposite edge flips")
        check(near(Geo.resize(r, handle: .left, to: CGPoint(x: 10, y: 0), keepAspect: false, fromCenter: true),
                   CGRect(x: 10, y: 0, width: 80, height: 50)), "⌥ resize mirrors around the centre")
        check(Geo.pixelAligned(CGRect(x: 0.3, y: 0.26, width: 10, height: 10), scale: 2) == CGRect(x: 0, y: 0, width: 10.5, height: 10.5),
              "pixel alignment rounds outward on the 2× grid")
        check(near(Geo.quadPoint(.zero, CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 0), 0.5), CGPoint(x: 5, y: 5)), "quadratic midpoint")
        let (pc, pe) = Geo.quadPrefix(.zero, CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 0), 0.5)
        check(near(pe, CGPoint(x: 5, y: 5)) && near(pc, CGPoint(x: 2.5, y: 5)), "de Casteljau split")
        check(Geo.segmentIntersectsRect(CGPoint(x: -5, y: 5), CGPoint(x: 15, y: 5), CGRect(x: 0, y: 0, width: 10, height: 10)), "segment crosses rect")
        check(!Geo.segmentIntersectsRect(CGPoint(x: -5, y: -5), CGPoint(x: 15, y: -5), CGRect(x: 0, y: 0, width: 10, height: 10)), "segment misses rect")
    }))

    SelfTest.cases.append(("Annotate.Snapping", {
        let moving = CGRect(x: 47, y: 0, width: 20, height: 20)
        let res = Snapping.snap(moving, targets: [CGRect(x: 0, y: 0, width: 50, height: 50)], canvas: nil, threshold: 5)
        check(near(res.offset.dx, 3), "left edge snaps to the target's right edge")
        check(near(res.offset.dy, 0) && res.guides.contains { $0.axis == .horizontal }, "top edge already aligned with the target top")
        let canvas = Snapping.snap(CGRect(x: 38, y: 300, width: 20, height: 20), targets: [], canvas: CGRect(x: 0, y: 0, width: 100, height: 100), threshold: 4)
        check(near(canvas.offset.dx, 2) && canvas.guides.first?.isCanvas == true, "centre snaps to the canvas centre")
        check(Snapping.snap(CGPoint(x: 98, y: 51), xs: [100], ys: [0], threshold: 3) == CGPoint(x: 100, y: 51), "point snapping per axis")
    }))

    SelfTest.cases.append(("Annotate.HitTesting", {
        let rect = Annotation(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 60), color: .black, lineWidth: 4, shadow: false)
        check(rect.hitTest(CGPoint(x: 11, y: 30), tolerance: 3), "rectangle border hit")
        check(!rect.hitTest(CGPoint(x: 60, y: 35), tolerance: 3), "hollow rectangle interior is click-through")
        var filled = rect; filled.kind = .filledRectangle
        check(filled.hitTest(CGPoint(x: 60, y: 35), tolerance: 3), "filled rectangle interior hit")
        var ellipse = rect; ellipse.kind = .ellipse
        check(ellipse.hitTest(CGPoint(x: 60, y: 10), tolerance: 3), "ellipse outline hit")
        check(!ellipse.hitTest(CGPoint(x: 12, y: 12), tolerance: 3), "ellipse bounding-box corner miss")
        let line = Annotation(kind: .line, start: .zero, end: CGPoint(x: 100, y: 100), color: .black, lineWidth: 2, shadow: false)
        check(line.hitTest(CGPoint(x: 52, y: 50), tolerance: 2), "line hit")
        check(!line.hitTest(CGPoint(x: 70, y: 30), tolerance: 2), "line miss")
        var pen = Annotation(kind: .pen, start: .zero, end: .zero, color: .black, lineWidth: 3, shadow: false)
        pen.points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)]
        check(pen.hitTest(CGPoint(x: 51, y: 25), tolerance: 2), "pen polyline hit")
        check(pen.frame == CGRect(x: 0, y: 0, width: 50, height: 50), "pen frame = point bounds")
        check(pen.intersects(CGRect(x: 40, y: -5, width: 20, height: 10)), "marquee touches pen")
        var counter = Annotation(kind: .counter, start: CGPoint(x: 100, y: 100), end: .zero, color: .black, lineWidth: 0, shadow: false)
        counter.fontSize = 30
        check(counter.frame == CGRect(x: 85, y: 85, width: 30, height: 30), "counter frame centred on start")
        var curved = Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 100, y: 0), color: .black, lineWidth: 4, shadow: false)
        curved.arrowStyle = .curved
        curved.control = CGPoint(x: 50, y: 80)
        check(curved.hitTest(CGPoint(x: 50, y: 40), tolerance: 2), "curved arrow hit on the curve")
        check(!curved.hitTest(CGPoint(x: 50, y: 0), tolerance: 2), "curved arrow miss on the chord")
        var text = Annotation(kind: .text, start: .zero, end: .zero, color: .black, lineWidth: 0, shadow: false)
        text.text = "Hi"
        let short = text.frame.width
        text.text = "Hello, world"
        check(text.frame.width > short, "text frame grows with its content")
        text.textWidth = 60
        check(near(text.frame.width, 60) && text.frame.height > 0, "wrapped text keeps its width")
    }))

    SelfTest.cases.append(("Annotate.ObjectTransforms", {
        let a = Annotation(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 20), color: .black, lineWidth: 2, shadow: false)
        check(a.moved(by: CGVector(dx: 5, dy: -5)).frame == CGRect(x: 15, y: 5, width: 20, height: 10), "move")
        let s = a.scaled(by: 2)
        check(s.frame == CGRect(x: 20, y: 20, width: 40, height: 20) && s.lineWidth == 4, "uniform scale scales width too")
        let r = Annotation.dragging(a, handle: .corner(.bottomRight), to: CGPoint(x: 50, y: 40), shift: false, option: false)
        check(r.frame == CGRect(x: 10, y: 10, width: 40, height: 30), "corner handle resize")
        let line = Annotation(kind: .line, start: .zero, end: CGPoint(x: 10, y: 0), color: .black, lineWidth: 2, shadow: false)
        let l = Annotation.dragging(line, handle: .end, to: CGPoint(x: 20, y: 19), shift: true, option: false)
        check(near(l.end.x, l.end.y), "⇧ end handle constrains to 45°")
        check(a.handles.count == 8 && line.handles.count == 2, "handle counts")
        var img = a; img.kind = .image
        let i = Annotation.dragging(img, handle: .corner(.bottomRight), to: CGPoint(x: 70, y: 20), shift: false, option: false)
        check(near(i.frame.width / i.frame.height, 2), "image objects keep aspect by default")
        let objs = [a, { var c = a; c.kind = .counter; c.number = 4; return c }()]
        check(objs.nextCounterNumber(start: 1) == 5 && [Annotation]().nextCounterNumber(start: 3) == 3, "next counter number")
        check(CounterStyle.letters.label(1) == "A" && CounterStyle.letters.label(27) == "AA" && CounterStyle.letters.label(52) == "AZ", "letter labels")
        check(CounterStyle.roman.label(1994) == "MCMXCIV" && CounterStyle.roman.label(4) == "IV", "roman labels")
    }))

    SelfTest.cases.append(("Annotate.Arrows", {
        let tip = CGPoint(x: 100, y: 0)
        for style in ArrowStyle.allCases {
            let g = ArrowGenerator.geometry(tail: .zero, tip: tip, control: CGPoint(x: 50, y: 40), width: 4, style: style)
            check(!g.heads.isEmpty && near(g.heads[0][0], tip), "\(style) head tip is at the arrow tip")
            check(!g.strokes.isEmpty || !g.fills.isEmpty, "\(style) produces geometry")
        }
        let double = ArrowGenerator.geometry(tail: .zero, tip: tip, control: nil, width: 4, style: .double)
        check(double.heads.count == 2 && near(double.heads[1][0], .zero), "double-headed arrow has a head at the tail")
        let std = ArrowGenerator.geometry(tail: .zero, tip: tip, control: nil, width: 4, style: .standard)
        let shaftBox = std.strokes[0].path.boundingBox
        check(shaftBox.maxX < tip.x, "standard shaft stops inside the head")
        let curved = ArrowGenerator.geometry(tail: .zero, tip: tip, control: CGPoint(x: 100, y: 100), width: 4, style: .curved)
        // Tangent at the tip points straight up (−y), so the head base lies below the tip.
        check(curved.heads[0][1].y > tip.y + 1, "curved head follows the curve's tangent")
        let fancy = ArrowGenerator.geometry(tail: .zero, tip: tip, control: nil, width: 6, style: .fancy)
        check(fancy.fills.count == 1 && fancy.strokes.isEmpty, "tapered arrow is a single filled outline")
        check(ArrowGenerator.geometry(tail: .zero, tip: .zero, control: nil, width: 4, style: .standard).heads.isEmpty, "zero-length arrow is empty")
        check(ArrowGenerator.headLength(for: 10) > ArrowGenerator.headLength(for: 2), "heads scale with thickness")
    }))

    SelfTest.cases.append(("Annotate.Smoothing", {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10)]
        let ch = PathSmoothing.chaikin(pts)
        check(ch.count == 2 * (pts.count - 1) + 2, "Chaikin point count")
        check(ch.first == pts.first && ch.last == pts.last, "Chaikin keeps the endpoints")
        var ends: [CGPoint] = []
        PathSmoothing.catmullRomPath(pts).applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint: ends.append(el.points[0])
            case .addCurveToPoint: ends.append(el.points[2])
            default: break
            }
        }
        check(ends == pts, "Catmull-Rom passes through every input point")
        let dense = (0...100).map { CGPoint(x: CGFloat($0) * 0.1, y: 0) }
        let thin = PathSmoothing.thinned(dense, minDistance: 1)
        check(thin.count < 15 && thin.first == dense.first && thin.last == dense.last, "thinning keeps endpoints and drops dense samples")
    }))

    SelfTest.cases.append(("Annotate.UndoStack", {
        var u = UndoStack<Int>(limit: 3)
        check(!u.canUndo && !u.canRedo, "empty")
        u.record(1); u.record(2)
        check(u.undo(current: 3) == 2 && u.undo(current: 2) == 1, "undo returns states in reverse")
        check(u.undo(current: 1) == nil, "nothing left to undo")
        check(u.redo(current: 1) == 2 && u.redo(current: 2) == 3, "redo walks forward")
        u.record(3)
        check(!u.canRedo, "a new change clears redo")
        u.record(4); u.record(5); u.record(6)
        check(u.undoStates == [4, 5, 6], "history is capped at the limit")
    }))

    SelfTest.cases.append(("Annotate.Layout", {
        let img = testImage(200, 100)
        var s = CanvasState(image: img, scale: 2)
        check(s.imageSize == CGSize(width: 100, height: 50), "document points = pixels ÷ scale")
        check(s.contentBounds(expand: true) == s.imageRect, "no objects → image bounds")
        let outside = Annotation(kind: .filledRectangle, start: CGPoint(x: 90, y: 40), end: CGPoint(x: 130, y: 70), color: .black, lineWidth: 0, shadow: false)
        s.objects = [outside]
        let grown = s.contentBounds(expand: true)
        check(grown.maxX >= 130 && grown.maxY >= 70 && grown.minX == 0, "canvas expands to fit objects")
        check(s.contentBounds(expand: false) == s.imageRect, "expansion can be turned off")
        s.cropRect = CGRect(x: 10, y: 10, width: 20, height: 20)
        check(s.contentBounds(expand: true) == CGRect(x: 10, y: 10, width: 20, height: 20), "crop wins over expansion")

        var bg = BackgroundSettings()
        let plain = CompositionLayout.make(contentBounds: CGRect(x: 0, y: 0, width: 100, height: 50), background: bg, scale: 1)
        check(plain.outputSize == CGSize(width: 100, height: 50) && plain.contentRect.origin == .zero, "no background → output is the content")
        bg.fill = .color(.white); bg.padding = 10; bg.inset = 0; bg.aspect = .square
        let sq = CompositionLayout.make(contentBounds: CGRect(x: 0, y: 0, width: 100, height: 50), background: bg, scale: 1)
        check(sq.outputSize == CGSize(width: 120, height: 120), "1:1 ratio grows the short side")
        check(sq.contentRect == CGRect(x: 10, y: 35, width: 100, height: 50), "content centred inside the padding")
        bg.alignment = .topLeft
        let tl = CompositionLayout.make(contentBounds: CGRect(x: 0, y: 0, width: 100, height: 50), background: bg, scale: 1)
        check(tl.contentRect.origin == CGPoint(x: 10, y: 10), "top-left alignment respects padding")
        bg.alignment = .center; bg.aspect = .auto; bg.inset = 5
        let inset = CompositionLayout.make(contentBounds: CGRect(x: -20, y: 0, width: 100, height: 50), background: bg, scale: 1)
        check(inset.frameRect == CGRect(x: 10, y: 10, width: 110, height: 60) && inset.contentRect.origin == CGPoint(x: 15, y: 15), "inset frame")
        check(inset.documentToOutput == CGVector(dx: 35, dy: 15), "document → output translation")
    }))

    SelfTest.cases.append(("Annotate.Export", {
        var s = CanvasState(image: testImage(40, 20), scale: 2)
        let flat = AnnotateComposer.render(s)
        check(flat?.width == 40 && flat?.height == 20, "export keeps full Retina pixel size")
        s.background.fill = .color(.black)
        s.background.padding = 5
        s.background.shadow = 0
        let padded = AnnotateComposer.render(s)
        check(padded?.width == 60 && padded?.height == 40, "background padding is in points (×2 pixels)")
        let margins = testImage(30, 30, transparentMargin: 5)
        check(ImageAnalysis.opaqueBounds(of: margins) == CGRect(x: 5, y: 5, width: 20, height: 20), "opaque bounds ignore transparent margins")
        let corner = ImageAnalysis.cornerColor(of: testImage(4, 4))
        check(corner.r > 0.9 && corner.b < 0.1, "corner colour samples the top-left pixel")
    }))

    SelfTest.cases.append(("Annotate.Document", {
        var s = CanvasState(image: testImage(8, 6), scale: 2)
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 1, y: 1), end: CGPoint(x: 3.5, y: 2), color: RGBAColor(r: 1, g: 0, b: 0), lineWidth: 3, shadow: true)
        arrow.arrowStyle = .curved; arrow.control = CGPoint(x: 2, y: 0)
        var text = Annotation(kind: .text, start: .zero, end: .zero, color: .white, lineWidth: 0, shadow: false)
        text.text = "Résumé ✅"; text.textStyle = .roundedBox; text.textWidth = 120
        var img = Annotation(kind: .image, start: .zero, end: CGPoint(x: 2, y: 2), color: .black, lineWidth: 0, shadow: false)
        img.imagePNG = ImageTools.pngData(testImage(2, 2))
        s.objects = [arrow, text, img]
        s.cropRect = CGRect(x: 0, y: 0, width: 3, height: 2)
        s.background.fill = .gradient("lagoon"); s.background.padding = 32; s.background.alignment = .bottomRight
        s.spotlightOpacity = 0.7; s.counterStart = 5
        do {
            let data = try SuperScreenshotDocument.encode(s, sourceURL: URL(fileURLWithPath: "/tmp/a.png"))
            let back = try SuperScreenshotDocument.decode(data)
            check(back.state.objects == s.objects, "objects round-trip")
            check(back.state.background == s.background && back.state.cropRect == s.cropRect, "background + crop round-trip")
            check(back.state.scale == 2 && back.state.image.width == 8 && back.state.image.height == 6, "image + scale round-trip")
            check(back.state.spotlightOpacity == 0.7 && back.state.counterStart == 5, "document settings round-trip")
            check(back.sourceURL?.path == "/tmp/a.png", "source path round-trip")
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            check(json?["format"] as? String == SuperScreenshotDocument.typeIdentifier, "format header")
            // Projects saved before the rename carry the legacy format id and extension.
            json?["format"] = SuperScreenshotDocument.legacyTypeIdentifier
            let legacy = try SuperScreenshotDocument.decode(JSONSerialization.data(withJSONObject: json ?? [:]))
            check(legacy.state.objects == s.objects, "legacy-format project opens")
            check(SuperScreenshotDocument.isDocument(URL(fileURLWithPath: "/tmp/p.\(SuperScreenshotDocument.legacyFileExtension)"))
                  && SuperScreenshotDocument.isDocument(URL(fileURLWithPath: "/tmp/p.SUPERSCREENSHOT"))
                  && !SuperScreenshotDocument.isDocument(URL(fileURLWithPath: "/tmp/p.png")), "project extensions")
        } catch {
            check(false, "document round-trip threw \(error)")
        }
        var threw = false
        do { _ = try SuperScreenshotDocument.decode(Data("{\"hello\":1}".utf8)) } catch { threw = true }
        check(threw, "non-project JSON is rejected")
        var newer = false
        let future = "{\"format\":\"\(SuperScreenshotDocument.typeIdentifier)\",\"version\":99}"
        do { _ = try SuperScreenshotDocument.decode(Data(future.utf8)) } catch SuperScreenshotDocument.DocumentError.newerVersion(99) { newer = true } catch {}
        check(newer, "newer format versions give a specific error")
        check(RecentProjects.updated(["/a", "/b", "/c"], adding: "/b", limit: 3) == ["/b", "/a", "/c"], "recent projects de-duplicate")
        check(RecentProjects.updated(["/a", "/b", "/c"], adding: "/d", limit: 3) == ["/d", "/a", "/b"], "recent projects are capped")
    }))

    SelfTest.cases.append(("Annotate.Recovery", {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("superscreenshot-recovery-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        var s = CanvasState(image: testImage(8, 6), scale: 2)
        s.objects = [Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 2, y: 2), color: .black, lineWidth: 1, shadow: false)]
        // What the recovery writer stores: a full document minus the Quick Look preview.
        do {
            let data = try SuperScreenshotDocument.encode(s, sourceURL: nil, includePreview: false)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            check(json?["preview"] == nil, "recovery copies skip the preview render")
            let decoded = try SuperScreenshotDocument.decode(data)
            check(decoded.state.objects == s.objects, "preview-free document round-trips")
        } catch { check(false, "recovery encoding threw \(error)") }
        // Scan: one good copy, one damaged copy (crash mid-write), one unrelated file.
        let good = AnnotateRecovery.fileURL(for: UUID(), in: folder)
        try? SuperScreenshotDocument.encode(s, sourceURL: nil, includePreview: false).write(to: good)
        let bad = AnnotateRecovery.fileURL(for: UUID(), in: folder)
        try? Data("{\"format\":\"\(SuperScreenshotDocument.typeIdentifier)\",\"version\":1,\"objects\":[".utf8).write(to: bad)
        let other = folder.appendingPathComponent("notes.txt")
        try? Data("x".utf8).write(to: other)
        check(AnnotateRecovery.pendingDocuments(in: folder).count == 2, "only .superscreenshot files are candidates")
        let loaded = AnnotateRecovery.load(in: folder)
        check(loaded.count == 1 && loaded.first?.url.lastPathComponent == good.lastPathComponent
              && loaded.first?.document.state.objects == s.objects, "readable copy is loaded")
        check(!fm.fileExists(atPath: bad.path) && fm.fileExists(atPath: other.path), "damaged copy is deleted, unrelated file untouched")
        check(AnnotateRecovery.pendingDocuments(in: folder.appendingPathComponent("missing")).isEmpty, "missing folder has nothing pending")
        // Writer: flush writes a pending copy now; discard removes it and beats a pending write.
        let w = RecoveryWriter(url: AnnotateRecovery.fileURL(for: UUID(), in: folder))
        w.schedule(s, sourceURL: URL(fileURLWithPath: "/tmp/src.png"), createdAt: Date(), delay: 60)
        check(!fm.fileExists(atPath: w.url.path), "write is debounced")
        w.flush()
        RecoveryWriter.drain()
        let back = (try? Data(contentsOf: w.url)).flatMap { try? SuperScreenshotDocument.decode($0) }
        check(back?.sourceURL?.path == "/tmp/src.png" && back?.state.objects == s.objects, "flushed copy is a complete document")
        w.discard()
        RecoveryWriter.drain()
        check(!fm.fileExists(atPath: w.url.path), "discard removes the copy")
        w.schedule(s, sourceURL: nil, createdAt: Date(), delay: 60)
        w.discard()
        w.flush()
        RecoveryWriter.drain()
        check(!fm.fileExists(atPath: w.url.path), "a pending write cannot resurrect a discarded copy")
    }))

    SelfTest.cases.append(("Annotate.AtomicSave", {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("superscreenshot-atomic-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        let file = dir.appendingPathComponent("shot.png")
        do {
            try ImageTools.write(testImage(4, 4), to: file, format: .png)
            let original = try Data(contentsOf: file)
            // Fault injection: the folder stops accepting new files (read-only disk, revoked permission).
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            var threw = false
            do { try ImageTools.write(testImage(9, 9), to: file, format: .png) } catch { threw = true }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            check(threw, "saving over a file in a read-only folder reports an error")
            check((try? Data(contentsOf: file)) == original, "the original file is left intact")
            check((try? fm.contentsOfDirectory(atPath: dir.path)) == ["shot.png"], "no half-written file is left behind")
        } catch { check(false, "atomic save test threw \(error)") }
    }))

    SelfTest.cases.append(("Annotate.ToolbarParity", {
        let tools = AnnotateTool.toolbarTools
        check(!tools.contains(.crop) && tools.first == .select && tools.last == .highlighter, "segmented tools exclude Crop and run Move → Highlighter")
        check(tools == [.select, .rectangle, .filledRectangle, .ellipse, .line, .arrow, .text, .pixelate, .spotlight, .counter, .pen, .highlighter],
              "tool order matches CleanShot X 5.0")
        let keys = AnnotateTool.allCases.map(\.key)
        check(Set(keys).count == keys.count, "single-key shortcuts are unique")
        check(AnnotateTool.forKey("k") == .crop && AnnotateTool.forKey("c") == .counter && AnnotateTool.forKey("p") == .pixelate &&
              AnnotateTool.forKey("h") == .spotlight && AnnotateTool.forKey("d") == .pen && AnnotateTool.forKey("m") == .highlighter &&
              AnnotateTool.forKey("e") == .ellipse, "CleanShot shortcuts")
        check(AnnotateTool.forKey("b") == nil, "B is left for the Background tool")
        check(ColorPalette.presets.count == 10 && ColorPalette.presets.first?.name == "Black" && ColorPalette.presets.last?.name == "White",
              "ten default colours, black first, white last")
        check(GradientPreset.all.count == 20 && GradientPreset.defaultVisibleCount == 10, "20 gradients, 10 shown collapsed")
        check(Set(GradientPreset.all.map(\.id)).count == GradientPreset.all.count, "gradient ids are unique")
        check(BackgroundColors.saturated.count == 8 && BackgroundColors.pastel.count == 8, "plain colour rows (plus a special tile each)")
    }))

    SelfTest.cases.append(("Annotate.BackgroundFills", {
        var s = CanvasState(image: testImage(20, 10), scale: 1)
        s.background.padding = 10
        s.background.shadow = 0
        s.background.cornerRadius = 0
        for kind in BlurredBackground.allCases {
            s.background.fill = .blurred(kind)
            guard let img = AnnotateComposer.render(s) else { check(false, "\(kind) renders"); continue }
            check(img.width == 40 && img.height == 30, "\(kind) blurred fill keeps the padded size")
            check(alpha(at: 0, 0, in: img) == 255, "\(kind) blurred fill is opaque")
        }
        s.background.fill = .color(BackgroundColors.transparent)
        if let img = AnnotateComposer.render(s) {
            check(img.width == 40 && alpha(at: 0, 0, in: img) == 0 && alpha(at: 20, 15, in: img) == 255,
                  "transparent fill keeps padding but no backdrop")
        } else { check(false, "transparent fill renders") }
        do {
            var bg = BackgroundSettings()
            bg.fill = .blurred(.gray)
            let back = try JSONDecoder().decode(BackgroundSettings.self, from: JSONEncoder().encode(bg))
            check(back == bg, "blurred fill round-trips through JSON")
        } catch { check(false, "blurred fill coding threw \(error)") }
    }))

    /// Alpha of pixel (x, y) counted from the top-left.
    func alpha(at x: Int, _ y: Int, in img: CGImage) -> UInt8 {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return px[3]
    }
}
