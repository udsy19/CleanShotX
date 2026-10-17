import AppKit
import SuperScreenshotCore

/// Font, attributes and measurement for text objects (shared by the renderer and the inline editor).
enum TextLayout {
    /// Inner padding around the text (room for the outline / box).
    static func padding(_ a: Annotation) -> CGFloat { (a.fontSize * 0.28).rounded() }

    static func font(_ a: Annotation) -> NSFont {
        let size = max(4, a.fontSize)
        switch a.textStyle {
        case .monospaced, .monospacedBox:
            return .monospacedSystemFont(ofSize: size, weight: .semibold)
        case .rounded, .roundedBox:
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        case .outline:
            return .systemFont(ofSize: size, weight: .heavy)
        case .standard, .box:
            return .systemFont(ofSize: size, weight: .semibold)
        }
    }

    /// Colour of the glyph fill.
    static func textColor(_ a: Annotation) -> NSColor {
        let c = a.textStyle.hasBox ? a.color.contrasting : (a.textStyle == .outline ? a.color.contrasting : a.color)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static func attributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        return [.font: font(a), .foregroundColor: textColor(a), .paragraphStyle: para]
    }

    static func attributed(_ a: Annotation) -> NSAttributedString {
        NSAttributedString(string: a.text.isEmpty ? " " : a.text, attributes: attributes(a))
    }

    /// Size of the text block without padding.
    static func textSize(_ a: Annotation) -> CGSize {
        let maxW = a.textWidth.map { max(1, $0 - padding(a) * 2) } ?? 100_000
        var s = attributed(a).boundingRect(with: CGSize(width: maxW, height: 100_000),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        // A trailing newline isn't counted by boundingRect; add a line so the caret has room.
        if a.text.hasSuffix("\n") { s.height += font(a).ascender - font(a).descender + font(a).leading }
        let w = a.textWidth.map { max(1, $0 - padding(a) * 2) } ?? ceil(s.width)
        return CGSize(width: max(w, a.fontSize * 0.5), height: ceil(max(s.height, a.fontSize * 1.2)))
    }

    /// Size of the whole object (text + padding).
    static func size(of a: Annotation) -> CGSize {
        let t = textSize(a), p = padding(a)
        return CGSize(width: t.width + p * 2, height: t.height + p * 2)
    }
}
