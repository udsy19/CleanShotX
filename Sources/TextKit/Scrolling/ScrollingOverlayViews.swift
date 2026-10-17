import AppKit
import QuartzCore
import ShotcraftCore

// MARK: - Dimmed frame around the area (click-through)

final class AreaFrameView: NSView {
    /// Area in this view's coordinates.
    var area: CGRect = .zero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: area))
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        outside.fill()

        // 1 pt white border with a faint dark outer stroke, just outside the captured pixels.
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let halo = NSBezierPath(rect: area.insetBy(dx: -1.5, dy: -1.5))
        halo.lineWidth = 1
        halo.stroke()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: area.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
    }
}

// MARK: - Alert pill (SGAlert / PauseSGAlert / PermanentWarningSGAlert)

@MainActor final class HintPanel {
    enum Style { case info, warning }

    private let panel = OverlayPanel(clickThrough: true, shadow: true)
    private let pill = PillLabelView(style: .light, fontSize: 13)
    private var hideWork: DispatchWorkItem?
    private(set) var currentText: String?
    /// Where to centre the pill (global Cocoa coordinates).
    var anchor: CGPoint = .zero

    init() { panel.contentView = pill }

    /// Shows `text`; `duration` nil keeps it until replaced or hidden.
    func show(_ text: String, symbol: String, style: Style = .info, duration: TimeInterval? = nil, shake: Bool = false) {
        hideWork?.cancel()
        hideWork = nil
        let changed = currentText != text
        currentText = text
        pill.set(text, symbol: symbol, tint: style == .warning ? .systemOrange : nil)
        if changed || !panel.isVisible {
            let size = pill.fittingSize
            panel.setFrame(NSRect(x: (anchor.x - size.width / 2).rounded(), y: (anchor.y - size.height / 2).rounded(),
                                  width: size.width, height: size.height), display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if shake { self.shake() }
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    /// Hides the pill; with `text`, only if that text is the one showing.
    func hide(_ text: String? = nil) {
        if let text, text != currentText { return }
        hideWork?.cancel()
        hideWork = nil
        currentText = nil
        panel.orderOut(nil)
    }

    private func shake() {
        guard let layer = pill.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -9, 9, -6, 6, -3, 3, 0]
        a.duration = 0.4
        layer.add(a, forKey: "shake")
    }
}

// MARK: - Live preview (stitched image so far)

final class StitchPreviewView: NSView {
    var parts: [CGImage] = [] { didSet { needsDisplay = true } }
    var axis: ScrollAxis = .vertical { didSet { needsDisplay = true } }

    /// Length along the axis of all parts drawn at `breadth` points across.
    static func scaledLength(of parts: [CGImage], axis: ScrollAxis, breadth: CGFloat) -> CGFloat {
        guard let first = parts.first else { return 0 }
        let across = CGFloat(axis == .vertical ? first.width : first.height)
        guard across > 0 else { return 0 }
        return parts.reduce(0) { $0 + CGFloat(axis == .vertical ? $1.height : $1.width) } * breadth / across
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let first = parts.first else { return }
        ctx.interpolationQuality = .medium
        let across = CGFloat(axis == .vertical ? first.width : first.height)
        guard across > 0 else { return }
        if axis == .vertical {
            let scale = bounds.width / across
            let total = Self.scaledLength(of: parts, axis: axis, breadth: bounds.width)
            // Newest content anchored at the bottom once it no longer fits.
            var top = bounds.maxY + max(0, total - bounds.height)
            for p in parts {
                let h = CGFloat(p.height) * scale
                let rect = CGRect(x: 0, y: top - h, width: bounds.width, height: h)
                if rect.intersects(dirtyRect) { ctx.draw(p, in: rect) }
                top -= h
            }
        } else {
            let scale = bounds.height / across
            let total = Self.scaledLength(of: parts, axis: axis, breadth: bounds.height)
            var left = bounds.minX - max(0, total - bounds.width)
            for p in parts {
                let w = CGFloat(p.width) * scale
                let rect = CGRect(x: left, y: 0, width: w, height: bounds.height)
                if rect.intersects(dirtyRect) { ctx.draw(p, in: rect) }
                left += w
            }
        }
    }
}

/// White card docked outside the area — right side, bottom-aligned, growing taller (vertical) or above the area,
/// left-aligned, growing wider (horizontal).
@MainActor final class PreviewPanel {
    private static let breadth: CGFloat = 165       // card width for vertical captures
    private static let stripHeight: CGFloat = 100   // card height for horizontal captures
    private static let padding: CGFloat = 3
    private static let gap: CGFloat = 10

    private let panel = OverlayPanel(clickThrough: true, shadow: true)
    private let imageView = StitchPreviewView()

    init() {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 6
        card.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]
        card.addSubview(imageView)
        panel.contentView = card
    }

    func hide() { panel.orderOut(nil) }

    func update(_ u: ScrollUpdate, area: CGRect, screen: NSScreen) {
        imageView.axis = u.partsAxis
        imageView.parts = u.parts
        let inner = (u.partsAxis == .vertical ? Self.breadth : Self.stripHeight) - 2 * Self.padding
        let length = StitchPreviewView.scaledLength(of: u.parts, axis: u.partsAxis, breadth: inner) + 2 * Self.padding
        guard let frame = Self.frame(for: length, axis: u.partsAxis, area: area, visible: screen.visibleFrame) else {
            panel.orderOut(nil); return
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        imageView.frame = panel.contentView?.bounds.insetBy(dx: Self.padding, dy: Self.padding) ?? .zero
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    static func frame(for length: CGFloat, axis: ScrollAxis, area: CGRect, visible vis: CGRect) -> CGRect? {
        let b = breadth, g = gap
        if axis == .vertical {
            guard vis.height > 2 * g + 40 else { return nil }
            let bottom = max(area.minY, vis.minY + g)
            let maxLength = max(40, min(vis.maxY - g - bottom, max(area.height, 240)))
            let h = min(max(length, 40), maxLength).rounded()
            if area.maxX + g + b <= vis.maxX { return CGRect(x: area.maxX + g, y: bottom, width: b, height: h) }
            if area.minX - g - b >= vis.minX { return CGRect(x: area.minX - g - b, y: bottom, width: b, height: h) }
            return nil
        }
        let h = stripHeight
        guard vis.width > 2 * g + 60 else { return nil }
        let left = max(area.minX, vis.minX + g)
        let maxLength = max(60, min(vis.maxX - g - left, max(area.width, 320)))
        let w = min(max(length, 60), maxLength).rounded()
        if area.maxY + g + h <= vis.maxY { return CGRect(x: left, y: area.maxY + g, width: w, height: h) }
        if area.minY - g - h >= vis.minY { return CGRect(x: left, y: area.minY - g - h, width: w, height: h) }
        return nil
    }
}
