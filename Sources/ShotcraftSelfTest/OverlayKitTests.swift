import Foundation
import CoreGraphics
import ShotcraftCore
import OverlayKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
func registerOverlayKitTests() {
    SelfTest.cases.append(("OverlayKit.cardSize", {
        let normal = QuickAccessLayout.cardSize(for: CGSize(width: 1600, height: 1000), scale: 1)
        check(normal == CGSize(width: 174, height: 124), "16:10 card at the default size is ~174×124 (ui-reference §4)")
        let square = QuickAccessLayout.cardSize(for: CGSize(width: 500, height: 500), scale: 1)
        check(square == CGSize(width: 174, height: 174), "height follows the aspect inside the clamp")
        let wide = QuickAccessLayout.cardSize(for: CGSize(width: 1000, height: 100), scale: 1)
        check(wide.height == 124, "very wide media clamps to min aspect")
        let tall = QuickAccessLayout.cardSize(for: CGSize(width: 100, height: 1000), scale: 1)
        check(tall.height == 218, "very tall media clamps to max aspect")
        check(QuickAccessLayout.cardSize(for: .zero, scale: 1).width == 174, "zero size falls back")
        check(QuickAccessLayout.cardSize(for: CGSize(width: 10, height: 10), scale: 3).width == 244, "scale clamped to 1.4")
        check(QuickAccessLayout.cardSize(for: CGSize(width: 10, height: 10), scale: 0.1).width == 104, "scale clamped to 0.6")
    }))

    SelfTest.cases.append(("OverlayKit.thumbnailMaxPixel", {
        let card = CGSize(width: 174, height: 124)
        check(QuickAccessLayout.thumbnailMaxPixel(card: card, media: CGSize(width: 1740, height: 1240), backingScale: 2) == 348,
              "matching aspect: card width × backing scale")
        let wide = QuickAccessLayout.thumbnailMaxPixel(card: card, media: CGSize(width: 3000, height: 1000), backingScale: 2)
        check(wide == 744, "wide capture cropped by aspect-fill still fills the card height without upscaling")
        check(QuickAccessLayout.thumbnailMaxPixel(card: card, media: .zero, backingScale: 2) == 348, "unknown size falls back")
    }))

    SelfTest.cases.append(("OverlayKit.stackLayout", {
        let vis = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let card = CGSize(width: 200, height: 125)
        let two = QuickAccessLayout.layout(newestFirst: [card, card], in: vis, side: .left, scale: 1)
        check(two.cards[0] == CGRect(x: 16, y: 16, width: 200, height: 125), "newest at bottom-left")
        check(two.cards[1] == CGRect(x: 16, y: 153, width: 200, height: 125), "older stacked above with spacing")
        check(two.header == nil, "no header below threshold")

        let right = QuickAccessLayout.layout(newestFirst: [card], in: vis, side: .right, scale: 1)
        check(right.cards[0]?.minX == 784, "right side aligned to edge margin")

        let offset = CGRect(x: 1000, y: -200, width: 1000, height: 800)   // secondary display
        let o = QuickAccessLayout.layout(newestFirst: [card], in: offset, side: .left, scale: 1)
        check(o.cards[0]?.origin == CGPoint(x: 1016, y: -184), "respects screen origin")

        let three = QuickAccessLayout.layout(newestFirst: [card, card, card], in: vis, side: .left, scale: 1)
        let top = three.cards[2]!
        check(three.header == CGRect(x: 16, y: top.maxY + 12, width: 174, height: 30), "header above the topmost card")

        let short = CGRect(x: 0, y: 0, width: 1000, height: 300)
        let overflow = QuickAccessLayout.layout(newestFirst: Array(repeating: card, count: 5), in: short, side: .left, scale: 1)
        check(overflow.cards[0] != nil, "newest always placed")
        check(overflow.cards.dropFirst().allSatisfy { $0 == nil }, "older cards hidden when full")
        if let h = overflow.header { check(h.maxY <= short.maxY - 16, "header stays on screen") } else { check(false, "header shown") }

        let scaled = QuickAccessLayout.layout(newestFirst: [QuickAccessLayout.cardSize(for: CGSize(width: 16, height: 10), scale: 1.4)],
                                              in: vis, side: .left, scale: 1.4)
        check(scaled.cards[0] == CGRect(x: 22, y: 22, width: 244, height: 173), "margins scale with size")

        let peek = QuickAccessLayout.slidDownFrame(for: two.cards[0]!, in: offset)
        check(peek.maxY == offset.minY + QuickAccessLayout.slideDownPeek && peek.size == card && peek.minX == 16,
              "slid-down card only peeks above the bottom edge")

        let start = QuickAccessLayout.offscreenFrame(for: two.cards[0]!, in: vis, side: .left)
        check(start.maxX < vis.minX && start.minY == 16, "slide-in starts past the left edge")
        let startR = QuickAccessLayout.offscreenFrame(for: right.cards[0]!, in: vis, side: .right)
        check(startR.minX > vis.maxX, "slide-in starts past the right edge")
        check(QuickAccessLayout.isAtEdge(CGPoint(x: 2, y: 400), of: vis, side: .left), "left edge hit")
        check(!QuickAccessLayout.isAtEdge(CGPoint(x: 500, y: 400), of: vis, side: .left), "middle is not an edge")
        check(QuickAccessLayout.isAtEdge(CGPoint(x: 999, y: 400), of: vis, side: .right), "right edge hit")
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
