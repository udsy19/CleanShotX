import Foundation
import CoreGraphics
import SuperScreenshotCore
import OverlayKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
func registerOverlayKitTests() {
    SelfTest.cases.append(("OverlayKit.cardSize", {
        check(QuickAccessSize.widths == [140, 168, 210, 250, 350], "popupSize widths table (binary)")
        let sizes = (0...4).map { QuickAccessLayout.cardSize(sizeIndex: $0) }
        check(sizes.map(\.width) == QuickAccessSize.widths, "width per size index")
        check(sizes.allSatisfy { $0.height == ($0.width / 1.4).rounded() }, "height = width / 1.4 for every index")
        check(sizes[2] == CGSize(width: 210, height: 150), "default index is 210×150")
        check(sizes[0] == CGSize(width: 140, height: 100) && sizes[4] == CGSize(width: 350, height: 250), "smallest and largest")
        check(QuickAccessLayout.cardSize(sizeIndex: -3) == sizes[0] && QuickAccessLayout.cardSize(sizeIndex: 9) == sizes[4],
              "out-of-range index clamped")
        check(QuickAccessSize.defaultIndex(mainScreenWidth: 1512) == 2, "wide main screen defaults to 210 pt")
        check(QuickAccessSize.defaultIndex(mainScreenWidth: 900) == 1, "≤ 900 pt main screen defaults to 168 pt")
        check((0...4).map { QuickAccessLayout.cornerButtonSide(sizeIndex: $0) } == [18, 20, 22, 24, 26],
              "corner buttons are 18 + 2 × size index")
    }))

    SelfTest.cases.append(("OverlayKit.thumbnailMaxPixel", {
        let card = CGSize(width: 210, height: 150)
        check(QuickAccessLayout.thumbnailMaxPixel(card: card, media: CGSize(width: 2100, height: 1500), backingScale: 2) == 420,
              "matching aspect: card width × backing scale")
        let wide = QuickAccessLayout.thumbnailMaxPixel(card: card, media: CGSize(width: 3000, height: 1000), backingScale: 2)
        check(wide == 900, "wide capture cropped by aspect-fill still fills the card height without upscaling")
        check(QuickAccessLayout.thumbnailMaxPixel(card: card, media: .zero, backingScale: 2) == 420, "unknown size falls back")
    }))

    SelfTest.cases.append(("OverlayKit.stackLayout", {
        // 14" MacBook Pro: 1512×982 pt frame; the visible frame loses the menu bar and the Dock.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)
        let card = QuickAccessLayout.cardSize(sizeIndex: 2)
        let left = QuickAccessLayout.layout(count: 3, cardSize: card, screen: screen, visible: visible, side: .left)
        check(left.cards == [CGRect(x: 40, y: 100, width: 210, height: 150), CGRect(x: 40, y: 260, width: 210, height: 150),
                             CGRect(x: 40, y: 420, width: 210, height: 150)],
              "left: 40 pt side margin, newest 100 pt above the screen frame's bottom, 10 pt gaps")
        let right = QuickAccessLayout.layout(count: 3, cardSize: card, screen: screen, visible: visible, side: .right)
        check(right.cards == [CGRect(x: 1262, y: 100, width: 210, height: 150), CGRect(x: 1262, y: 260, width: 210, height: 150),
                              CGRect(x: 1262, y: 420, width: 210, height: 150)],
              "right: maxX − width − 40")
        check(left.header == CGRect(x: 40, y: 580, width: 210, height: 30), "header above the topmost card, card-wide")
        check(QuickAccessLayout.layout(count: 2, cardSize: card, screen: screen, visible: visible, side: .left).header == nil,
              "no header below threshold")

        let offset = CGRect(x: 1512, y: -200, width: 1000, height: 800)   // secondary display
        let o = QuickAccessLayout.layout(count: 1, cardSize: card, screen: offset, visible: offset, side: .left)
        check(o.cards[0]?.origin == CGPoint(x: 1552, y: -100), "respects the screen origin")

        let overflow = QuickAccessLayout.layout(count: 7, cardSize: card, screen: screen, visible: visible, side: .left)
        check(overflow.cards.prefix(5).allSatisfy { $0 != nil }, "five cards fit under the menu bar with the header")
        check(overflow.cards.dropFirst(5).allSatisfy { $0 == nil }, "older cards hidden when full")
        if let h = overflow.header { check(h.maxY <= visible.maxY, "header stays on screen") } else { check(false, "header shown") }

        let first = left.cards[0]!
        let peek = QuickAccessLayout.slidDownFrame(for: first, in: visible)
        check(peek.maxY == visible.minY + QuickAccessLayout.slideDownPeek && peek.size == card && peek.minX == 40,
              "slid-down card only peeks above the bottom edge")

        check(QuickAccessLayout.edgeFrame(for: first, side: .left) == first.offsetBy(dx: -69, dy: 0), "entrance starts 69 pt left")
        let firstR = right.cards[0]!
        check(QuickAccessLayout.edgeFrame(for: firstR, side: .right) == firstR.offsetBy(dx: 69, dy: 0), "…or 69 pt right")
        check(QuickAccessLayout.isAtEdge(CGPoint(x: 2, y: 400), of: screen, side: .left), "left edge hit")
        check(!QuickAccessLayout.isAtEdge(CGPoint(x: 500, y: 400), of: screen, side: .left), "middle is not an edge")
        check(QuickAccessLayout.isAtEdge(CGPoint(x: 1511, y: 400), of: screen, side: .right), "right edge hit")
    }))

    SelfTest.cases.append(("OverlayKit.motionCurves", {
        // Offset from the resting x of a card entering from 69 pt toward the edge (measured at 120 Hz).
        func offset(_ t: Double) -> Double { -69 + 69 * QuickAccessMotion.spring(t) }
        check(QuickAccessMotion.spring(0) == 0 && offset(0) == -69, "starts 69 pt toward the edge")
        check(abs(offset(0.19) - 5) <= 2, "≈ +5 pt past rest at 0.19 s (got \(offset(0.19)))")
        let samples = stride(from: 0.0, through: 0.6, by: 1.0 / 120).map { ($0, offset($0)) }
        let peak = samples.max { $0.1 < $1.1 }!
        check(abs(peak.0 - 0.19) <= 0.02 && abs(peak.1 - 5) <= 0.5, "overshoot peaks ≈ 5 pt at ≈ 0.19 s")
        check(samples.filter { $0.0 >= 0.3 }.allSatisfy { abs($0.1) <= 1 }, "within 1 pt of rest from 0.3 s on")
        check(QuickAccessMotion.spring(QuickAccessMotion.springDuration) == 1, "snaps to rest at the end")
        check(QuickAccessMotion.easeOut(0) == 0 && QuickAccessMotion.easeOut(1) == 1 && QuickAccessMotion.easeOut(0.5) > 0.5,
              "fade-in eases out")
        check(QuickAccessMotion.easeIn(0) == 0 && QuickAccessMotion.easeIn(1) == 1 && QuickAccessMotion.easeIn(0.5) < 0.5,
              "exit eases in")
        check(QuickAccessMotion.easeOut(2) == 1 && QuickAccessMotion.easeIn(-1) == 0, "progress clamped")
    }))

    SelfTest.cases.append(("OverlayKit.pinGeometry", {
        let vis = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let m = PinGeometry.fittingMagnification(imageSize: CGSize(width: 4000, height: 2000), visible: vis)
        check(abs(m - 0.2125) < 0.0001, "large image fitted to 85% of the screen")
        check(PinGeometry.fittingMagnification(imageSize: CGSize(width: 100, height: 100), visible: vis) == 1, "small image not upscaled")
        let f = PinGeometry.scaled(frame: CGRect(x: 100, y: 100, width: 200, height: 100), imageSize: CGSize(width: 200, height: 100),
                                   magnification: 2, anchor: CGPoint(x: 200, y: 150))
        check(f == CGRect(x: 0, y: 50, width: 400, height: 200), "zoom keeps the anchor fixed")
        let tiny = PinGeometry.scaled(frame: f, imageSize: CGSize(width: 200, height: 100), magnification: 0.001, anchor: CGPoint(x: 0, y: 50))
        check(tiny.width == 20, "magnification clamped to minimum")
    }))

    SelfTest.cases.append(("OverlayKit.historyRoundTrip", {
        let a = HistoryEntry(id: UUID(), url: URL(fileURLWithPath: "/tmp/a b.png"), kind: .image, mode: .area,
                             date: Date(timeIntervalSince1970: 1_700_000_000.250), width: 2880, height: 1800, scale: 2,
                             isSaved: false)
        let b = HistoryEntry(id: UUID(), url: URL(fileURLWithPath: "/tmp/b.mp4"), kind: .video, mode: .recording,
                             date: Date(timeIntervalSince1970: 1_700_000_000.750), width: 1920, height: 1080, scale: 1,
                             isSaved: true, uploadedURL: URL(string: "https://example.com/x"), projectURL: nil)
        guard let data = try? HistoryIndex.encode([a, b]) else { check(false, "encodes"); return }
        let back = HistoryIndex.decode(data)
        check(back.count == 2, "two entries")
        check(back.first?.id == b.id, "newest first after decode (sub-second ordering kept)")
        func same(_ x: HistoryEntry, _ y: HistoryEntry) -> Bool {
            var y2 = y; y2.date = x.date
            return x == y2 && abs(x.date.timeIntervalSince(y.date)) < 0.002
        }
        check(back.count == 2 && same(back[1], a) && same(back[0], b), "fields survive round-trip")
        let json = String(data: data, encoding: .utf8) ?? ""
        check(json.contains("\"version\" : 1") && json.contains("\"isSaved\""), "versioned, readable JSON")

        // Lenient decode: a corrupt item doesn't discard the rest.
        if var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var items = obj["items"] as? [Any] {
            items.append(["id": "not-a-uuid"])
            obj["items"] = items
            let corrupted = try! JSONSerialization.data(withJSONObject: obj)
            check(HistoryIndex.decode(corrupted).count == 2, "corrupt item skipped")
        } else { check(false, "json shape") }
        check(HistoryIndex.decode(Data("garbage".utf8)).isEmpty, "garbage decodes to empty")

        let media = b.makeMedia()
        check(HistoryEntry(media) == b, "entry ↔ CapturedMedia")
        check(media.uploadedURL == b.uploadedURL && media.pixelSize == CGSize(width: 1920, height: 1080), "media fields")

        var a2 = a; a2.isSaved = true
        let up = HistoryIndex.upsert(a2, into: [a, b])
        check(up.count == 2 && up.first { $0.id == a.id }?.isSaved == true, "upsert replaces by id")
    }))

    SelfTest.cases.append(("OverlayKit.historyPrune", {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ name: String, daysAgo: Double, saved: Bool = false) -> HistoryEntry {
            HistoryEntry(id: UUID(), url: URL(fileURLWithPath: "/managed/Media/\(name).png"), kind: .image, mode: .area,
                         date: now.addingTimeInterval(-daysAgo * 86_400), width: 10, height: 10, scale: 1, isSaved: saved)
        }
        let fresh = entry("fresh", daysAgo: 1), old = entry("old", daysAgo: 10), gone = entry("gone", daysAgo: 1)
        let exists: (URL) -> Bool = { $0 != gone.url }
        let r = HistoryIndex.prune([fresh, old, gone], now: now, retentionDays: 7, fileExists: exists)
        check(r.kept.map(\.id) == [fresh.id], "fresh kept")
        check(r.expired.map(\.id) == [old.id], "old expired")
        check(r.missing.map(\.id) == [gone.id], "missing file dropped")
        let forever = HistoryIndex.prune([fresh, old, gone], now: now, retentionDays: 0, fileExists: exists)
        check(forever.kept.count == 2 && forever.expired.isEmpty, "0 days keeps everything that exists")
        let edge = entry("edge", daysAgo: 6.99)
        check(HistoryIndex.prune([edge], now: now, retentionDays: 7, fileExists: { _ in true }).kept.count == 1, "inside window kept")

        let managed = [URL(fileURLWithPath: "/managed/Media"), URL(fileURLWithPath: "/managed/Recordings")]
        check(HistoryIndex.shouldDeleteFile(of: old, managedDirectories: managed), "unsaved managed file deleted")
        check(!HistoryIndex.shouldDeleteFile(of: entry("s", daysAgo: 10, saved: true), managedDirectories: managed), "saved file kept")
        var outside = old; outside.url = URL(fileURLWithPath: "/Users/x/Desktop/old.png")
        check(!HistoryIndex.shouldDeleteFile(of: outside, managedDirectories: managed), "files outside managed folders kept")
        var sibling = old; sibling.url = URL(fileURLWithPath: "/managed/Media2/old.png")
        check(!HistoryIndex.shouldDeleteFile(of: sibling, managedDirectories: managed), "prefix-named sibling folder kept")
    }))

    SelfTest.cases.append(("OverlayKit.historyCorruption", {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("superscreenshot-history-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json"), backup = dir.appendingPathComponent("history.json.bak")
        func entry(_ name: String, _ t: Double) -> HistoryEntry {
            HistoryEntry(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(name).png"), kind: .image, mode: .area,
                         date: Date(timeIntervalSince1970: t), width: 10, height: 10, scale: 1, isSaved: false)
        }
        let good = try! HistoryIndex.encode([entry("a", 1), entry("b", 2)])
        try? good.write(to: file)
        check(HistoryIndex.load(from: file).count == 2 && !fm.fileExists(atPath: backup.path), "intact index loads without a backup")

        check(HistoryIndex.load(from: dir.appendingPathComponent("missing.json")).isEmpty, "missing file → empty history")
        try? Data().write(to: file)
        check(HistoryIndex.load(from: file).isEmpty && !fm.fileExists(atPath: backup.path), "empty file → empty history, no backup")

        // Truncated mid-write: whatever parses is kept and the original bytes are preserved in history.json.bak.
        let truncated = good.prefix(good.count / 2)
        try? truncated.write(to: file)
        let salvaged = HistoryIndex.load(from: file)
        check(salvaged.count <= 2, "truncated index never invents entries")
        check((try? Data(contentsOf: backup)) == truncated, "truncated index backed up byte for byte before anything rewrites it")

        try? Data("garbage".utf8).write(to: file)
        check(HistoryIndex.load(from: file).isEmpty && (try? Data(contentsOf: backup)) == Data("garbage".utf8), "garbage → empty, newer backup replaces the old one")
        try? Data("{\"version\": 1, \"items\": \"nope\"}".utf8).write(to: file)
        check(HistoryIndex.load(from: file).isEmpty, "wrong item type → empty, no crash")
        try? Data("[1, 2, 3]".utf8).write(to: file)
        check(HistoryIndex.load(from: file).isEmpty, "wrong top-level type → empty, no crash")

        // A newer file version with an extra field still loads what it can.
        var obj = try! JSONSerialization.jsonObject(with: good) as! [String: Any]
        obj["version"] = 99; obj["future"] = ["x": 1]
        try? JSONSerialization.data(withJSONObject: obj).write(to: file)
        check(HistoryIndex.load(from: file).count == 2, "future version with extra fields loads")
        if var items = obj["items"] as? [[String: Any]] {
            items[0]["kind"] = "hologram"
            obj["items"] = items
            try? JSONSerialization.data(withJSONObject: obj).write(to: file)
            check(HistoryIndex.load(from: file).count == 1, "unknown media kind skips that item only")
        }

        // Huge index: 5000 entries round-trip quickly.
        let many = (0..<5000).map { entry("m\($0)", Double($0)) }
        let start = Date()
        let big = try! HistoryIndex.encode(many)
        try? big.write(to: file)
        let loaded = HistoryIndex.load(from: file)
        check(loaded.count == 5000 && loaded.first?.date == Date(timeIntervalSince1970: 4999), "5000 entries survive, newest first")
        check(Date().timeIntervalSince(start) < 3, "large index loads in reasonable time (\(Date().timeIntervalSince(start)) s)")

        // Prune never reaches outside the managed folders, whatever the path looks like.
        let managed = [URL(fileURLWithPath: "/managed/Media")]
        var sneaky = entry("s", 1); sneaky.url = URL(fileURLWithPath: "/managed/Media/../../Users/x/Desktop/keep.png")
        check(!HistoryIndex.shouldDeleteFile(of: sneaky, managedDirectories: managed), "'..' traversal out of the managed folder is not deleted")
        var inside = entry("i", 1); inside.url = URL(fileURLWithPath: "/managed/Media/sub/../x.png")
        check(HistoryIndex.shouldDeleteFile(of: inside, managedDirectories: managed), "'..' that stays inside is still managed")
        var exact = entry("e", 1); exact.url = URL(fileURLWithPath: "/managed/Media")
        check(!HistoryIndex.shouldDeleteFile(of: exact, managedDirectories: managed), "the managed folder itself is never a deletable entry")
    }))

    SelfTest.cases.append(("OverlayKit.pinsStayOnScreen", {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 900), side = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let onMain = CGRect(x: 100, y: 100, width: 300, height: 200)
        check(PinGeometry.frameKeptOnScreen(onMain, screens: [main, side]) == onMain, "pin on a screen stays put")
        let onSide = CGRect(x: 2000, y: 300, width: 300, height: 200)
        check(PinGeometry.frameKeptOnScreen(onSide, screens: [main, side]) == onSide, "pin on the second display stays while it is attached")
        let moved = PinGeometry.frameKeptOnScreen(onSide, screens: [main])
        check(moved == CGRect(x: 1212, y: 300, width: 300, height: 200), "display unplugged: pin slides onto the remaining screen, same size, nearest spot")
        let peeking = CGRect(x: 1480, y: 300, width: 300, height: 200)   // 32 pt visible
        check(PinGeometry.frameKeptOnScreen(peeking, screens: [main]).maxX == 1512, "barely visible pin is pulled fully on screen")
        let partly = CGRect(x: 1400, y: 300, width: 300, height: 200)    // 112 pt visible
        check(PinGeometry.frameKeptOnScreen(partly, screens: [main]) == partly, "a pin that is reasonably visible is left where the user put it")
        let huge = CGRect(x: 3000, y: -500, width: 4000, height: 3000)
        let h = PinGeometry.frameKeptOnScreen(huge, screens: [main])
        check(h.minX == 0 && h.maxY == 900 && h.size == huge.size, "oversized pin aligns its top-left corner, never resized")
        check(PinGeometry.frameKeptOnScreen(onSide, screens: []) == onSide, "no screens at all: nothing to do")
    }))

    SelfTest.cases.append(("OverlayKit.hugeImagePreview", {
        // Pins and cards show a downsampled copy read straight from the file, never the full decode.
        let side = 4000   // 16 MP; a 10000 × 10000 all-in-one behaves the same, just slower to encode here
        let ctx = ImageTools.context(width: side, height: side)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 100, y: 100, width: 1500, height: 900))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("superscreenshot-huge-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try? ImageTools.write(ctx.makeImage()!, to: url, format: .png)
        let t0 = Date()
        let small = Thumbnailer.downsample(url, maxPixel: 3024)
        let downsampleTime = Date().timeIntervalSince(t0)
        check(small != nil && max(small!.width, small!.height) <= 3024, "preview bounded to one display's pixels (\(small?.width ?? 0) px)")
        let t1 = Date()
        let full = ImageTools.load(url)
        let fullBytes = ImageTools.context(width: full!.width, height: full!.height)
        fullBytes?.draw(full!, in: CGRect(x: 0, y: 0, width: full!.width, height: full!.height))
        let fullTime = Date().timeIntervalSince(t1)
        print("   huge image \(side)×\(side): downsampled preview \(small!.width)×\(small!.height) in \(Int(downsampleTime * 1000)) ms "
              + "(\(small!.width * small!.height * 4 / 1_000_000) MB) vs full decode in \(Int(fullTime * 1000)) ms (\(side * side * 4 / 1_000_000) MB)")
        check(downsampleTime < 5, "downsampling a 16 MP file is quick")
    }))

    SelfTest.cases.append(("OverlayKit.historyFilter", {
        check(HistoryIndex.Filter.screenshots.matches(.image) && !HistoryIndex.Filter.screenshots.matches(.gif), "screenshots")
        check(HistoryIndex.Filter.videos.matches(.video) && HistoryIndex.Filter.videos.matches(.studioProject), "videos")
        check(HistoryIndex.Filter.videos.title == "Videos", "5.0 filter pill title")
        check(HistoryIndex.Filter.gifs.matches(.gif) && !HistoryIndex.Filter.gifs.matches(.video), "gifs")
        check(MediaKind.allKindsForTest.allSatisfy { HistoryIndex.Filter.all.matches($0) }, "all")
    }))
}

private extension MediaKind {
    static let allKindsForTest: [MediaKind] = [.image, .video, .gif, .studioProject]
}
