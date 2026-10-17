import Foundation
import CoreGraphics

/// One recognized line of text. `box` uses a top-left origin (y grows downward) in any consistent unit (pixels).
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect
    public init(text: String, box: CGRect) { self.text = text; self.box = box }
}

/// Turns unordered OCR lines into reading-order text. Pure logic (no Vision), covered by self-tests.
public enum TextAssembler {

    /// A run of rows without a large vertical gap. `gapBefore` = visually separated from the previous paragraph.
    struct Paragraph { var rows: [String]; var gapBefore: Bool }

    public static func assemble(_ lines: [RecognizedLine], keepLineBreaks: Bool) -> String {
        let paragraphs = layout(lines)
        if keepLineBreaks {
            var out = ""
            for (i, p) in paragraphs.enumerated() {
                if i > 0 { out += p.gapBefore ? "\n\n" : "\n" }
                out += p.rows.joined(separator: "\n")
            }
            return out
        }
        return paragraphs.flatMap(\.rows).reduce("") { join($0, $1) }
    }

    // MARK: Joining

    private static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{00AD}"]

    /// Joins two fragments the way prose flows: de-hyphenates `exam-` + `ple`, no space next to CJK, else one space.
    public static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last else { return b }
        guard let first = b.first else { return a }
        if last.isWhitespace || first.isWhitespace { return a + b }
        if hyphens.contains(last), a.count >= 2, a[a.index(a.endIndex, offsetBy: -2)].isLetter, first.isLowercase {
            return String(a.dropLast()) + b
        }
        if isCJK(last) || isCJK(first) { return a + b }
        return a + " " + b
    }

    /// Han, kana, CJK punctuation and full-width forms — scripts written without inter-word spaces.
    public static func isCJK(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        switch s.value {
        case 0x3000...0x303F, 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// The text if it is exactly one web link (used for "Do you want to open this link?").
    public static func singleURL(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(t.startIndex..., in: t)
        guard let match = detector.firstMatch(in: t, options: [], range: range), match.range == range,
              let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    // MARK: Layout

    static func layout(_ input: [RecognizedLine]) -> [Paragraph] {
        let lines = input.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.box.height > 0 }
        guard !lines.isEmpty else { return [] }
        let unit = median(lines.map(\.box.height))
        var paragraphs: [Paragraph] = []
        for group in readingGroups(lines, unit: unit) {
            let rows = self.rows(of: group)
            var previous: Row?
            for row in rows {
                if let prev = previous, row.minY - prev.maxY <= unit * 1.5, !paragraphs.isEmpty {
                    paragraphs[paragraphs.count - 1].rows.append(row.text)
                } else {
                    let gap = previous.map { row.minY - $0.maxY > unit * 1.5 } ?? false
                    paragraphs.append(Paragraph(rows: [row.text], gapBefore: gap))
                }
                previous = row
            }
        }
        return paragraphs
    }

    struct Row {
        var lines: [RecognizedLine]
        var minY: CGFloat, maxY: CGFloat
        var text: String {
            lines.sorted { $0.box.minX < $1.box.minX }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .reduce("") { join($0, $1) }
        }
    }

    /// Lines that overlap vertically by ≥ 50 % of the shorter one form a row.
    static func rows(of lines: [RecognizedLine]) -> [Row] {
        var rows: [Row] = []
        for line in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if var last = rows.last {
                let overlap = min(last.maxY, line.box.maxY) - max(last.minY, line.box.minY)
                if overlap >= 0.5 * min(last.maxY - last.minY, line.box.height) {
                    last.lines.append(line)
                    last.minY = min(last.minY, line.box.minY); last.maxY = max(last.maxY, line.box.maxY)
                    rows[rows.count - 1] = last
                    continue
                }
            }
            rows.append(Row(lines: [line], minY: line.box.minY, maxY: line.box.maxY))
        }
        return rows
    }

    /// Splits lines into groups emitted in order: column segments (left → right) between full-width lines.
    static func readingGroups(_ lines: [RecognizedLine], unit: CGFloat) -> [[RecognizedLine]] {
        let minX = lines.map(\.box.minX).min() ?? 0, maxX = lines.map(\.box.maxX).max() ?? 0
        let width = maxX - minX
        guard lines.count >= 4, width > 0 else { return [lines] }

        let narrow = lines.filter { $0.box.width < width * 0.6 }
        let tolerance = max(unit, width * 0.02)
        var intervals: [ClosedRange<CGFloat>] = []
        for line in narrow.sorted(by: { $0.box.minX < $1.box.minX }) {
            if let last = intervals.last, line.box.minX <= last.upperBound + tolerance {
                intervals[intervals.count - 1] = last.lowerBound...max(last.upperBound, line.box.maxX)
            } else {
                intervals.append(line.box.minX...line.box.maxX)
            }
        }
        guard intervals.count >= 2 else { return [lines] }

        var columns: [[RecognizedLine]] = intervals.map { iv in narrow.filter { iv.contains($0.box.midX) } }
        // Every column must look like prose (lines filling most of its width); otherwise it's a table → rows.
        for (iv, members) in zip(intervals, columns) {
            let span = iv.upperBound - iv.lowerBound
            guard members.count >= 2, span > 0, median(members.map(\.box.width)) / span >= 0.45 else { return [lines] }
        }
        let spanning = lines.filter { $0.box.width >= width * 0.6 }.sorted { $0.box.minY < $1.box.minY }

        var groups: [[RecognizedLine]] = []
        func emitColumns(before limit: CGFloat) {
            for i in columns.indices {
                let part = columns[i].filter { $0.box.midY < limit }
                if !part.isEmpty { groups.append(part) }
                columns[i].removeAll { $0.box.midY < limit }
            }
        }
        for line in spanning {
            emitColumns(before: line.box.midY)
            groups.append([line])
        }
        emitColumns(before: .greatestFiniteMagnitude)
        return groups
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
