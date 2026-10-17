import Foundation
import CoreGraphics
import SuperScreenshotCore

public enum ScrollAxis: String, Codable, Sendable { case vertical, horizontal }

// MARK: - Frame analysis

/// Grayscale analysis of one captured frame, oriented so that "rows" run along the scroll axis
/// (image rows for vertical scrolling, image columns for horizontal scrolling).
public struct ScrollFrame {
    public let image: CGImage
    public let axis: ScrollAxis
    /// Pixels along the scroll axis.
    public let length: Int
    /// Pixels across the scroll axis.
    public let breadth: Int
    /// Exact FNV-1a hash of each full-resolution row.
    let rowHash: [UInt64]
    /// Row has enough contrast to be a reliable anchor (blank rows are ambiguous).
    let informative: [Bool]
    /// `length × columns` block means across each row; used for tolerant SAD comparison.
    let profile: [UInt8]
    let columns: Int

    public init?(image: CGImage, axis: ScrollAxis) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn = gray.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        self.image = image
        self.axis = axis
        let length = axis == .vertical ? h : w
        let breadth = axis == .vertical ? w : h
        let columns = min(breadth, 96)
        self.length = length; self.breadth = breadth; self.columns = columns

        var block = [Int](repeating: 0, count: breadth)
        var blockCount = [Int](repeating: 0, count: columns)
        for c in 0..<breadth { block[c] = c * columns / breadth; blockCount[block[c]] += 1 }

        var hashes = [UInt64](repeating: 0, count: length)
        var informative = [Bool](repeating: false, count: length)
        var profile = [UInt8](repeating: 0, count: length * columns)
        var sums = [Int](repeating: 0, count: columns)
        gray.withUnsafeBufferPointer { g in
            // Element (row r, column c) of the oriented frame.
            let rowStride = axis == .vertical ? w : 1
            let colStride = axis == .vertical ? 1 : w
            for r in 0..<length {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                var lo: UInt8 = 255, hi: UInt8 = 0
                for i in 0..<columns { sums[i] = 0 }
                var p = r * rowStride
                for c in 0..<breadth {
                    let v = g[p]
                    hash = (hash ^ UInt64(v)) &* 0x0000_0100_0000_01B3
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                    sums[block[c]] += Int(v)
                    p += colStride
                }
                hashes[r] = hash
                informative[r] = Int(hi) - Int(lo) > 16
                let base = r * columns
                for i in 0..<columns { profile[base + i] = UInt8(sums[i] / max(blockCount[i], 1)) }
            }
        }
        self.rowHash = hashes; self.informative = informative; self.profile = profile
    }
}

// MARK: - Offset detection

public enum FrameMatch: Equatable, Sendable {
    /// Content didn't move.
    case identical
    /// Content moved forward (scrolled down / right) by this many pixels.
    case moved(Int)
    /// Content moved backward (user scrolled up / left).
    case reversed(Int)
    /// Frames differ but no overlapping position was found (scrolled too fast, or animated content).
    case noOverlap
}

public enum OffsetDetector {
    public struct Outcome {
        public var match: FrameMatch
        /// Rows at the end of the frame excluded from matching (sticky footer / static margin).
        public var trailing: Int
        public var cost: Double
    }

    /// Max mean absolute block difference (0…255) for an overlap to count as the same content.
    static let maxCost = 2.5
    static let minBand = 16

    /// Leading/trailing rows that are unchanged at the same position (sticky header/footer or static margins).
    static func staticRuns(_ a: ScrollFrame, _ b: ScrollFrame) -> (leading: Int, trailing: Int) {
        let n = a.length
        var lead = 0
        while lead < n && a.rowHash[lead] == b.rowHash[lead] { lead += 1 }
        var trail = 0
        while trail < n - lead && a.rowHash[n - 1 - trail] == b.rowHash[n - 1 - trail] { trail += 1 }
        return (lead, trail)
    }

    static func minOverlap(band: Int) -> Int { max(12, band / 10) }

    /// Mean absolute profile difference between `a[y + d]` and `b[y]` over the overlap inside `[lo, hi)`.
    /// Returns nil if the overlap is too small or the cost exceeds `limit` (early abandon).
    static func cost(_ a: ScrollFrame, _ b: ScrollFrame, offset d: Int, lo: Int, hi: Int, limit: Double) -> Double? {
        let start = max(lo, lo - d), end = min(hi, hi - d)
        let rows = end - start
        guard rows >= minOverlap(band: hi - lo) else { return nil }
        let cols = a.columns
        let budget = Int(limit * Double(rows * cols))
        var total = 0
        a.profile.withUnsafeBufferPointer { pa in
            b.profile.withUnsafeBufferPointer { pb in
                for y in start..<end {
                    let ia = (y + d) * cols, ib = y * cols
                    for i in 0..<cols { total += abs(Int(pa[ia + i]) - Int(pb[ib + i])) }
                    if total > budget { return }
                }
            }
        }
        guard total <= budget else { return nil }
        return Double(total) / Double(rows * cols)
    }

    /// Finds how far the content moved from `a` to `b`.
    /// - Parameters:
    ///   - fixedTrailing: footer size established by an earlier match (kept constant for stitching).
    ///   - hint: an external estimate (e.g. Vision registration); its sign is not trusted.
    public static func detect(_ a: ScrollFrame, _ b: ScrollFrame, fixedTrailing: Int? = nil, hint: (() -> Int?)? = nil) -> Outcome {
        let n = a.length
        guard b.length == n, b.breadth == a.breadth else { return Outcome(match: .noOverlap, trailing: fixedTrailing ?? 0, cost: .infinity) }
        if a.rowHash == b.rowHash { return Outcome(match: .identical, trailing: fixedTrailing ?? 0, cost: 0) }

        let runs = staticRuns(a, b)
        let trailing = max(runs.trailing, fixedTrailing ?? 0)
        let lo = runs.leading, hi = n - trailing
        // Almost everything is static: a caret blink, a hover effect… not a scroll.
        guard hi - lo >= minBand else { return Outcome(match: .identical, trailing: fixedTrailing ?? runs.trailing, cost: 0) }
        let resultTrailing = fixedTrailing ?? runs.trailing

        func outcome(_ d: Int, _ c: Double) -> Outcome {
            let m: FrameMatch = d == 0 ? .identical : (d > 0 ? .moved(d) : .reversed(-d))
            return Outcome(match: m, trailing: resultTrailing, cost: c)
        }

        // 1. Exact row-hash votes from rows that are informative and unique in both bands.
        var firstIndex: [UInt64: Int] = [:], duplicates = Set<UInt64>()
        for y in lo..<hi where a.informative[y] {
            let h = a.rowHash[y]
            if firstIndex[h] != nil { duplicates.insert(h) } else { firstIndex[h] = y }
        }
        var seenB: [UInt64: Int] = [:]
        for y in lo..<hi where b.informative[y] { seenB[b.rowHash[y], default: 0] += 1 }
        var votes: [Int: Int] = [:]
        for y in lo..<hi where b.informative[y] {
            let h = b.rowHash[y]
            guard seenB[h] == 1, !duplicates.contains(h), let ya = firstIndex[h] else { continue }
            votes[ya - y, default: 0] += 1
        }
        let informativeB = (lo..<hi).reduce(0) { $0 + (b.informative[$1] ? 1 : 0) }
        guard informativeB >= 4 else { return Outcome(match: .identical, trailing: resultTrailing, cost: 0) }

        var candidates = votes.sorted { $0.value != $1.value ? $0.value > $1.value : abs($0.key) < abs($1.key) }.prefix(4).map(\.key)
        if !candidates.contains(0) { candidates.append(0) }
        if let best = bestCandidate(candidates, a, b, lo, hi) { return outcome(best.0, best.1) }

        // 2. Coarse SAD search on vertically downsampled profiles, refined at full resolution.
        var refine: [Int] = []
        for dc in coarseSearch(a, b, lo: lo, hi: hi) { refine += Array(dc.offset - dc.step...dc.offset + dc.step) }
        // 3. External hint (Vision translational registration), both signs.
        if let h = hint?() { let m = abs(h); refine += Array(m - 3...m + 3) + Array(-m - 3 ... -m + 3) }
        if let best = bestCandidate(refine, a, b, lo, hi) { return outcome(best.0, best.1) }
        return Outcome(match: .noOverlap, trailing: resultTrailing, cost: .infinity)
    }

    private static func bestCandidate(_ offsets: [Int], _ a: ScrollFrame, _ b: ScrollFrame, _ lo: Int, _ hi: Int) -> (Int, Double)? {
        var best: (Int, Double)?
        for d in Set(offsets) where abs(d) < hi - lo {
            guard let c = cost(a, b, offset: d, lo: lo, hi: hi, limit: best.map { min($0.1, maxCost) } ?? maxCost) else { continue }
            if best == nil || c < best!.1 || (c == best!.1 && abs(d) < abs(best!.0)) { best = (d, c) }
        }
        return best
    }

    /// Best two offsets (in full-resolution rows) of a search over rows averaged in groups of `step`.
    static func coarseSearch(_ a: ScrollFrame, _ b: ScrollFrame, lo: Int, hi: Int) -> [(offset: Int, step: Int)] {
        let band = hi - lo, cols = a.columns
        let step = max(1, band / 200)
        let nb = band / step
        guard nb >= 8 else { return [] }
        func downsample(_ f: ScrollFrame) -> [Int] {
            var out = [Int](repeating: 0, count: nb * cols)
            for r in 0..<nb {
                for k in 0..<step {
                    let src = (lo + r * step + k) * cols
                    for i in 0..<cols { out[r * cols + i] += Int(f.profile[src + i]) }
                }
                for i in 0..<cols { out[r * cols + i] /= step }
            }
            return out
        }
        let da = downsample(a), db = downsample(b)
        let minOv = max(3, nb / 10)
        var results: [(Int, Double)] = []
        var limit = Double.infinity
        for d in -(nb - minOv)...(nb - minOv) {
            let start = max(0, -d), end = min(nb, nb - d)
            let rows = end - start
            let budget = limit.isFinite ? Int(limit * Double(rows * cols)) : Int.max
            var total = 0
            var y = start
            while y < end && total <= budget {
                let ia = (y + d) * cols, ib = y * cols
                for i in 0..<cols { total += abs(da[ia + i] - db[ib + i]) }
                y += 1
            }
            guard total <= budget else { continue }
            let c = Double(total) / Double(rows * cols)
            results.append((d, c))
            results.sort { $0.1 < $1.1 }
            // Keep the two best non-adjacent minima.
            var kept: [(Int, Double)] = []
            for r in results where kept.allSatisfy({ abs($0.0 - r.0) > 1 }) { kept.append(r); if kept.count == 2 { break } }
            results = kept
            if results.count == 2 { limit = results[1].1 }
        }
        return results.map { (offset: $0.0 * step, step: step) }
    }
}

// MARK: - Stitcher

/// Accumulates frames of a scrolling area into one long image.
///
/// Canvas = first frame up to its footer, then for every accepted frame the `d` new rows just above the footer,
/// then the latest frame's footer. Each new frame is compared with the last *accepted* frame, so scrolling
/// back and forth recovers automatically.
public final class ScrollStitcher {
    public enum Event: Equatable, Sendable { case started, identical, appended(Int), reversed, noOverlap, limitReached }

    public let axis: ScrollAxis
    public let maxLength: Int
    /// Optional external offset estimator `(previous, next, axis) → pixels` used when pixel matching fails.
    public var hint: ((CGImage, CGImage, ScrollAxis) -> Int?)?

    private var reference: ScrollFrame?
    private var strips: [CGImage] = []
    private var trailing: Int?
    /// Stitched length (pixels along the axis) excluding the trailing footer.
    private var contentLength = 0
    public private(set) var acceptedFrames = 0
    public private(set) var isLimitReached = false

    public init(axis: ScrollAxis, maxLength: Int = 30_000) {
        self.axis = axis; self.maxLength = maxLength
    }

    /// Pixel size of the image `render()` would produce.
    public var pixelSize: CGSize {
        guard let ref = reference else { return .zero }
        let len = trailing.map { contentLength + $0 } ?? ref.length
        return axis == .vertical ? CGSize(width: ref.breadth, height: len) : CGSize(width: len, height: ref.breadth)
    }

    @discardableResult
    public func add(_ image: CGImage) -> Event {
        guard let frame = ScrollFrame(image: image, axis: axis) else { return .noOverlap }
        guard let ref = reference else {
            reference = frame; acceptedFrames = 1; contentLength = frame.length
            return .started
        }
        if isLimitReached { return .limitReached }
        let hint = self.hint
        let outcome = OffsetDetector.detect(ref, frame, fixedTrailing: trailing,
                                            hint: hint.map { h in { h(ref.image, frame.image, self.axis) } })
        switch outcome.match {
        case .identical: return .identical
        case .reversed: return .reversed
        case .noOverlap: return .noOverlap
        case .moved(let d):
            if trailing == nil {
                trailing = outcome.trailing
                contentLength = ref.length - outcome.trailing
                if let head = copy(ref.image, from: 0, count: contentLength) { strips = [head] }
            }
            let t = trailing ?? 0
            var count = d
            let room = maxLength - t - contentLength
            if count >= room { count = max(0, room); isLimitReached = true }
            if count > 0, let strip = copy(frame.image, from: frame.length - t - d, count: count) {
                strips.append(strip); contentLength += count
            }
            reference = frame
            acceptedFrames += 1
            return isLimitReached ? .limitReached : .appended(d)
        }
    }

    /// The pieces of the stitched image in order (for live previews); cheap, no compositing.
    public func parts() -> [CGImage] {
        guard let ref = reference else { return [] }
        guard let t = trailing else { return [ref.image] }
        guard t > 0, let footer = crop(ref.image, from: ref.length - t, count: t) else { return strips }
        return strips + [footer]
    }

    /// Composites the stitched image.
    public func render() -> CGImage? {
        let pieces = parts()
        if pieces.count == 1 { return pieces[0] }
        let size = pixelSize
        guard !pieces.isEmpty, let ctx = ImageTools.context(width: Int(size.width), height: Int(size.height)) else { return nil }
        var offset = 0
        for p in pieces {
            if axis == .vertical {
                ctx.draw(p, in: CGRect(x: 0, y: Int(size.height) - offset - p.height, width: p.width, height: p.height))
                offset += p.height
            } else {
                ctx.draw(p, in: CGRect(x: offset, y: 0, width: p.width, height: p.height))
                offset += p.width
            }
        }
        return ctx.makeImage()
    }

    private func crop(_ image: CGImage, from start: Int, count: Int) -> CGImage? {
        let rect = axis == .vertical
            ? CGRect(x: 0, y: start, width: image.width, height: count)
            : CGRect(x: start, y: 0, width: count, height: image.height)
        return image.cropping(to: rect)
    }

    /// Crop copied into its own bitmap, so the (large) source frame can be released.
    private func copy(_ image: CGImage, from start: Int, count: Int) -> CGImage? {
        guard count > 0, let part = crop(image, from: start, count: count),
              let ctx = ImageTools.context(width: part.width, height: part.height) else { return nil }
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        return ctx.makeImage()
    }
}
