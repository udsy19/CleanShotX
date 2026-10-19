import CoreGraphics
import Foundation
import SuperScreenshotCore
import TextKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
func registerTextKitTests() {
    SelfTest.cases.append(("TextKit.join", {
        check(TextAssembler.join("Hello", "world") == "Hello world", "plain words get one space")
        check(TextAssembler.join("hyphen-", "ated text") == "hyphenated text", "de-hyphenates lowercase continuation")
        check(TextAssembler.join("Jean-", "Paul") == "Jean- Paul", "keeps hyphen before capitalised word")
        check(TextAssembler.join("日本", "語です") == "日本語です", "no space between CJK")
        check(TextAssembler.join("価格は", "100円") == "価格は100円", "no space at CJK boundary")
        check(TextAssembler.join("한국어", "문장") == "한국어 문장", "Hangul keeps spaces")
        check(TextAssembler.join("end ", "start") == "end start", "no double space")
        check(TextAssembler.join("", "x") == "x" && TextAssembler.join("x", "") == "x", "empty sides")
    }))

    SelfTest.cases.append(("TextKit.assemble", {
        func line(_ t: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, h: CGFloat = 20) -> RecognizedLine {
            RecognizedLine(text: t, box: CGRect(x: x, y: y, width: w, height: h))
        }
        // Shuffled input → reading order by y.
        let simple = [line("second line", 0, 30, 200), line("first line", 0, 0, 180), line("third", 0, 60, 90)]
        check(TextAssembler.assemble(simple, keepLineBreaks: true) == "first line\nsecond line\nthird", "lines ordered top→bottom")
        check(TextAssembler.assemble(simple, keepLineBreaks: false) == "first line second line third", "joined without breaks")

        let hyphenated = [line("An exam-", 0, 0, 200), line("ple of text", 0, 26, 200)]
        check(TextAssembler.assemble(hyphenated, keepLineBreaks: false) == "An example of text", "hyphenated line end")
        check(TextAssembler.assemble(hyphenated, keepLineBreaks: true) == "An exam-\nple of text", "line breaks kept verbatim")

        // Fragments on one row (Vision splits at wide gaps).
        let row = [line("Total:", 0, 0, 60), line("$42.00", 300, 2, 60, h: 18)]
        check(TextAssembler.assemble(row, keepLineBreaks: true) == "Total: $42.00", "same-row fragments joined")

        // Blank line between paragraphs.
        let paras = [line("Para one", 0, 0, 150), line("Para two", 0, 80, 150)]
        check(TextAssembler.assemble(paras, keepLineBreaks: true) == "Para one\n\nPara two", "paragraph gap preserved")

        // Two prose columns under a full-width heading.
        let columns = [
            line("A heading that spans both columns", 0, 0, 420),
            line("left one", 0, 40, 190), line("right one", 230, 40, 190),
            line("left two", 0, 66, 185), line("right two", 230, 66, 188),
            line("left three", 0, 92, 170), line("right three", 230, 92, 160),
        ]
        check(TextAssembler.assemble(columns, keepLineBreaks: true)
              == "A heading that spans both columns\nleft one\nleft two\nleft three\nright one\nright two\nright three",
              "columns read left column first")

        // Table-like layout (short cells) stays row-wise.
        let table = [
            line("Name", 0, 0, 40), line("Value", 300, 0, 45),
            line("Alpha", 0, 26, 45), line("1", 300, 26, 10),
            line("Beta", 0, 52, 38), line("2", 300, 52, 10),
        ]
        check(TextAssembler.assemble(table, keepLineBreaks: true) == "Name Value\nAlpha 1\nBeta 2", "tables read row by row")
        check(TextAssembler.assemble([], keepLineBreaks: true).isEmpty, "empty input")
    }))

    SelfTest.cases.append(("TextKit.urlAndLanguages", {
        check(TextAssembler.singleURL(in: " https://example.com/a?b=1 \n")?.host == "example.com", "single URL detected")
        check(TextAssembler.singleURL(in: "see https://example.com") == nil, "URL with other text ignored")
        check(TextAssembler.singleURL(in: "hello") == nil, "plain word is not a URL")
        let supported = ["en-US", "fr-FR", "zh-Hans", "zh-Hant", "de-DE", "nb-NO"]
        check(TextRecognizer.normalizedLanguages(["en-us", "zh-CN", "zh_TW", "de", "xx-YY", "en-GB"], supported: supported)
              == ["en-US", "zh-Hans", "zh-Hant", "de-DE"], "language codes normalised to Vision's")
    }))

    SelfTest.cases.append(("TextKit.stitchVertical", { stitchCase(axis: .vertical) }))
    SelfTest.cases.append(("TextKit.stitchHorizontal", { stitchCase(axis: .horizontal) }))

    SelfTest.cases.append(("TextKit.stitchEdgeCases", {
        // Tiny area (40 px along the axis, no header/footer) scrolled in small steps still stitches exactly.
        let content = TextKitFixture.content(length: 160, breadth: 40, seed: 3)
        let tiny = ScrollStitcher(axis: .vertical)
        for s in [0, 0, 8, 16, 16, 30, 44, 60, 80, 100, 120] {
            _ = tiny.add(TextKitFixture.window(content, start: s, length: 40, header: nil, footer: nil, axis: .vertical))
        }
        let expected = TextKitFixture.image(content.px, length: 160, breadth: 40, axis: .vertical)
        if let r = tiny.render() {
            check(TextKitFixture.pixels(r) == TextKitFixture.pixels(expected), "tiny area stitched exactly (\(r.width)×\(r.height))")
        } else { check(false, "tiny area renders") }

        // Blank / uniform frames never count as movement; a frame of another size is rejected, not stitched.
        let blank = TextKitFixture.Buffer(length: 120, breadth: 80, px: [UInt8](repeating: 255, count: 120 * 80 * 4))
        var grey = blank; for i in stride(from: 0, to: grey.px.count, by: 4) { grey.px[i] = 200; grey.px[i + 1] = 200; grey.px[i + 2] = 200 }
        let flat = ScrollStitcher(axis: .vertical)
        let img = { (b: TextKitFixture.Buffer) in TextKitFixture.image(b.px, length: b.length, breadth: b.breadth, axis: .vertical) }
        check(flat.add(img(blank)) == .started, "first blank frame")
        check(flat.add(img(blank)) == .identical, "identical blank frames")
        check(flat.add(img(grey)) == .identical, "uniform colour change is not a scroll")
        check(flat.add(TextKitFixture.window(content, start: 0, length: 40, header: nil, footer: nil, axis: .vertical)) == .noOverlap,
              "frame of a different size rejected")
        check(flat.render().map { $0.width == 80 && $0.height == 120 } ?? false, "first frame kept as the result")
    }))

    SelfTest.cases.append(("TextKit.stitchKeepsPartialResult", {
        // The window closes (or another app comes to the front) mid-capture: later frames show unrelated content.
        // Whatever was stitched before must survive and render; nothing is thrown away.
        let content = TextKitFixture.content(length: 800, breadth: 120, seed: 11)
        let other = TextKitFixture.content(length: 800, breadth: 120, seed: 12)
        let stitcher = ScrollStitcher(axis: .vertical)
        for s in [0, 50, 100, 150] { _ = stitcher.add(TextKitFixture.window(content, start: s, length: 200, header: nil, footer: nil, axis: .vertical)) }
        let before = stitcher.pixelSize
        var events: [ScrollStitcher.Event] = []
        for s in [0, 40, 90] { events.append(stitcher.add(TextKitFixture.window(other, start: s, length: 200, header: nil, footer: nil, axis: .vertical))) }
        check(events.allSatisfy { $0 == .noOverlap }, "unrelated content never stitches (\(events))")
        check(stitcher.pixelSize == before && before.height == 350, "stitched length unchanged by the foreign frames")
        check(stitcher.render().map { $0.height == 350 } ?? false, "partial result renders after the failure")

        // Frames of another size (display or window geometry changed) are rejected, the result still renders.
        let resized = TextKitFixture.window(content, start: 0, length: 120, header: nil, footer: nil, axis: .vertical)
        check(stitcher.add(resized) == .noOverlap && stitcher.render() != nil, "size change rejected, result kept")

        // A single frame is a valid result (the user pressed Done without scrolling).
        let single = ScrollStitcher(axis: .vertical)
        check(single.render() == nil && single.pixelSize == .zero, "nothing captured → no image, no crash")
        _ = single.add(TextKitFixture.window(content, start: 0, length: 200, header: nil, footer: nil, axis: .vertical))
        check(single.render().map { $0.height == 200 } ?? false, "one frame renders as-is")
    }))

    SelfTest.cases.append(("TextKit.ocrRobustness", {
        // Vision on degenerate input must not crash; failures surface as errors or empty results.
        func blank(_ w: Int, _ h: Int) -> CGImage {
            let ctx = ImageTools.context(width: w, height: h)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()!
        }
        let auto = TextRecognizer.Configuration(automaticLanguage: true, languages: [])
        let r = try? TextRecognizer.recognize(in: blank(64, 64), configuration: auto)
        check(r.map { $0.lines.isEmpty && $0.barcodes.isEmpty } ?? true, "blank image → no text (or a clean error), no crash")
        _ = try? TextRecognizer.recognize(in: blank(1, 1), configuration: auto)
        check(true, "1 × 1 image survives")
        let bogus = TextRecognizer.Configuration(automaticLanguage: false, languages: ["xx-YY", "klingon"])
        check(TextRecognizer.normalizedLanguages(bogus.languages).isEmpty, "unsupported languages are dropped…")
        _ = try? TextRecognizer.recognize(in: blank(64, 64), configuration: bogus)
        check(true, "…and recognition with only unsupported languages still runs")
    }))

    SelfTest.cases.append(("TextKit.offsetDetection", {
        let content = TextKitFixture.content(length: 600, breadth: 160, seed: 7)
        func frame(_ start: Int, jitter: Bool = false) -> ScrollFrame {
            ScrollFrame(image: TextKitFixture.window(content, start: start, length: 240, header: nil, footer: nil, axis: .vertical, jitter: jitter),
                        axis: .vertical)!
        }
        let a = frame(100)
        check(OffsetDetector.detect(a, frame(100)).match == .identical, "identical frames")
        check(OffsetDetector.detect(a, frame(137)).match == .moved(37), "forward offset")
        check(OffsetDetector.detect(a, frame(60)).match == .reversed(40), "scrolled back")
        check(OffsetDetector.detect(a, frame(100 + 239)).match == .noOverlap, "no overlap → slow down")
        // Every row perturbed: no exact hash matches, the coarse SAD search must find it.
        check(OffsetDetector.detect(a, frame(171, jitter: true)).match == .moved(71), "coarse search with noisy frames")
    }))
}

/// Synthesises a tall page with a sticky header/footer, scrolls a window over it in uneven steps (with pauses,
/// a scroll-back and a too-fast jump) and checks the stitched image equals the original page pixel for pixel.
private func stitchCase(axis: ScrollAxis) {
    let breadth = 150, window = 260, header = 28, footer = 22
    let band = window - header - footer
    let content = TextKitFixture.content(length: 1400, breadth: breadth, seed: axis == .vertical ? 1 : 2)
    let headerImg = TextKitFixture.content(length: header, breadth: breadth, seed: 99)
    let footerImg = TextKitFixture.content(length: footer, breadth: breadth, seed: 98)

    var starts = [0, 0, 35, 120, 120, 90, 200, 330, 330 + band + 5, 410, 520]   // includes pause, scroll-back, overshoot
    var rng = TextKitFixture.LCG(seed: 5)
    while let last = starts.last, last < 1400 - band { starts.append(min(1400 - band, last + 20 + Int(rng.next() % 140))) }

    let stitcher = ScrollStitcher(axis: axis)
    var events: [ScrollStitcher.Event] = []
    for s in starts {
        events.append(stitcher.add(TextKitFixture.window(content, start: s, length: band, header: headerImg, footer: footerImg, axis: axis)))
    }
    check(events.first == .started, "\(axis): first frame starts")
    check(events.contains(.identical), "\(axis): pause detected")
    check(events.contains(.reversed), "\(axis): scroll-back detected")
    check(events.contains(.noOverlap), "\(axis): overshoot detected")

    guard let result = stitcher.render() else { check(false, "\(axis): render"); return }
    let expected = TextKitFixture.page(content, header: headerImg, footer: footerImg, axis: axis)
    check(result.width == expected.width && result.height == expected.height,
          "\(axis): size \(result.width)×\(result.height) vs \(expected.width)×\(expected.height)")
    check(TextKitFixture.pixels(result) == TextKitFixture.pixels(expected), "\(axis): stitched pixels equal the original")

    let capped = ScrollStitcher(axis: axis, maxLength: 500)
    var capEvent: ScrollStitcher.Event = .started
    for s in stride(from: 0, through: 1000, by: 60) {
        capEvent = capped.add(TextKitFixture.window(content, start: s, length: band, header: headerImg, footer: footerImg, axis: axis))
    }
    let cappedLength = axis == .vertical ? capped.pixelSize.height : capped.pixelSize.width
    check(capEvent == .limitReached && cappedLength == 500, "\(axis): length capped (\(cappedLength))")
}

/// Image fixtures in the oriented frame of reference: "length" runs along the scroll axis.
private enum TextKitFixture {
    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }

    /// Oriented RGBA buffer: `length` lines of `breadth` pixels.
    struct Buffer { var length: Int; var breadth: Int; var px: [UInt8] }

    /// Text-like noise: 12-px "lines" of random blocks separated by 4-px blank gaps.
    static func content(length: Int, breadth: Int, seed: UInt64) -> Buffer {
        var rng = LCG(seed: seed)
        var px = [UInt8](repeating: 255, count: length * breadth * 4)
        for r in 0..<length where r % 16 < 12 {
            var c = 0
            while c < breadth {
                let v = UInt8(rng.next() % 256), tint = UInt8(rng.next() % 256)
                for k in c..<min(breadth, c + 3) {
                    let i = (r * breadth + k) * 4
                    px[i] = v; px[i + 1] = tint; px[i + 2] = v / 2; px[i + 3] = 255
                }
                c += 3
            }
        }
        return Buffer(length: length, breadth: breadth, px: px)
    }

    static func slice(_ b: Buffer, _ start: Int, _ count: Int) -> [UInt8] {
        Array(b.px[(start * b.breadth * 4)..<((start + count) * b.breadth * 4)])
    }

    static func image(_ lines: [UInt8], length: Int, breadth: Int, axis: ScrollAxis) -> CGImage {
        let w = axis == .vertical ? breadth : length, h = axis == .vertical ? length : breadth
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for l in 0..<length {
            for c in 0..<breadth {
                let src = (l * breadth + c) * 4
                let (x, y) = axis == .vertical ? (c, l) : (l, c)
                let dst = (y * w + x) * 4
                out[dst..<dst + 4] = lines[src..<src + 4]
            }
        }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(out) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func window(_ content: Buffer, start: Int, length: Int, header: Buffer?, footer: Buffer?, axis: ScrollAxis,
                       jitter: Bool = false) -> CGImage {
        var lines = (header?.px ?? []) + slice(content, start, length) + (footer?.px ?? [])
        let total = (header?.length ?? 0) + length + (footer?.length ?? 0)
        if jitter {
            var rng = LCG(seed: UInt64(start))
            for l in 0..<total {
                let i = (l * content.breadth + Int(rng.next() % UInt64(content.breadth))) * 4
                lines[i] = lines[i] < 250 ? lines[i] + 3 : lines[i] - 3
            }
        }
        return image(lines, length: total, breadth: content.breadth, axis: axis)
    }

    static func page(_ content: Buffer, header: Buffer, footer: Buffer, axis: ScrollAxis) -> CGImage {
        image(header.px + content.px + footer.px, length: header.length + content.length + footer.length,
              breadth: content.breadth, axis: axis)
    }

    /// Normalised RGBA bytes for comparison.
    static func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = ImageTools.context(width: image.width, height: image.height)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let count = ctx.bytesPerRow * image.height
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: count))
    }
}
