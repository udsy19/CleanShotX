import AppKit
import QuartzCore
import ShotcraftCore

extension NSWindow.Level {
    /// Above regular app windows (the area being scrolled) but below system UI.
    static let scrollingOverlay = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
}

/// Borderless panel that may become key (for Return/Esc key equivalents) without activating the app.
final class ScrollingPanel: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, clickThrough: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = !clickThrough
        level = .scrollingOverlay
        ignoresMouseEvents = clickThrough
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// HUD-material rounded container used by all scrolling-capture panels.
@MainActor func makeHUDBackground(cornerRadius: CGFloat) -> NSVisualEffectView {
    let fx = NSVisualEffectView()
    fx.material = .hudWindow
    fx.blendingMode = .behindWindow
    fx.state = .active
    fx.wantsLayer = true
    fx.layer?.cornerRadius = cornerRadius
    fx.layer?.masksToBounds = true
    return fx
}

// MARK: - Dimmed frame around the area (click-through)

final class AreaFrameView: NSView {
    /// Area in this view's coordinates.
    var area: CGRect = .zero { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: area))
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        outside.fill()

        let border = NSBezierPath(rect: area.insetBy(dx: -1.5, dy: -1.5))
        border.lineWidth = 2
        (isActive ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.9)).setStroke()
        border.stroke()
    }
}

// MARK: - Hint pill (SGAlert)

@MainActor final class HintPanel {
    enum Style { case info, warning }

    let panel = ScrollingPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), clickThrough: true)
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private(set) var currentText: String?
    /// Where to centre the pill (global Cocoa coordinates).
    var anchor: CGPoint = .zero

    init() {
        let fx = makeHUDBackground(cornerRadius: 17)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel.contentView = fx
    }

    /// Shows `text`; `duration` nil keeps it until replaced or hidden.
    func show(_ text: String, symbol: String, style: Style = .info, duration: TimeInterval? = nil, shake: Bool = false) {
        hideWork?.cancel()
        let changed = currentText != text
        currentText = text
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = style == .warning ? .systemOrange : .controlAccentColor
        if changed || !panel.isVisible {
            let size = panel.contentView?.fittingSize ?? .zero
            panel.setFrame(NSRect(x: (anchor.x - size.width / 2).rounded(), y: (anchor.y - size.height / 2).rounded(),
                                  width: size.width, height: size.height), display: true)
        }
        if !panel.isVisible { panel.alphaValue = 1; panel.orderFrontRegardless() }
        if shake { self.shake() }
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func hide(_ text: String? = nil) {
        if let text, text != currentText { return }
        hideWork?.cancel()
        currentText = nil
        panel.orderOut(nil)
    }

    private func shake() {
        guard let layer = panel.contentView?.layer else { return }
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let first = parts.first else { return }
        ctx.interpolationQuality = .medium
        let breadth = CGFloat(axis == .vertical ? first.width : first.height)
        guard breadth > 0 else { return }
        if axis == .vertical {
            let scale = bounds.width / breadth
            let total = parts.reduce(0) { $0 + CGFloat($1.height) } * scale
            // Newest content anchored at the bottom once it no longer fits.
            var top = bounds.maxY + max(0, total - bounds.height)
            for p in parts {
                let h = CGFloat(p.height) * scale
                let rect = CGRect(x: 0, y: top - h, width: bounds.width, height: h)
                if rect.intersects(bounds) { ctx.draw(p, in: rect) }
                top -= h
            }
        } else {
            let scale = bounds.height / breadth
            let total = parts.reduce(0) { $0 + CGFloat($1.width) } * scale
            var left = bounds.minX - max(0, total - bounds.width)
            for p in parts {
                let w = CGFloat(p.width) * scale
                let rect = CGRect(x: left, y: 0, width: w, height: bounds.height)
                if rect.intersects(bounds) { ctx.draw(p, in: rect) }
                left += w
            }
        }
    }
}

@MainActor final class PreviewPanel {
    let panel = ScrollingPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 300), clickThrough: true)
    let imageView = StitchPreviewView()
    private let sizeLabel = NSTextField(labelWithString: "")

    init() {
        let fx = makeHUDBackground(cornerRadius: 10)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .center
        for v in [imageView, sizeLabel] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; fx.addSubview(v) }
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: fx.topAnchor, constant: 8),
            sizeLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 5),
            sizeLabel.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 6),
            sizeLabel.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -6),
            sizeLabel.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -6),
        ])
        panel.contentView = fx
    }

    func update(_ u: ScrollUpdate) {
        imageView.axis = u.partsAxis
        imageView.parts = u.parts
        sizeLabel.stringValue = "\(Int(u.pixelSize.width)) × \(Int(u.pixelSize.height)) px"
    }

    /// Beside the area (vertical) or below/above it (horizontal), inside the screen's visible frame.
    func place(around area: CGRect, on screen: NSScreen, axis: ScrollAxis, avoiding controls: CGRect) {
        let vis = screen.visibleFrame
        let gap: CGFloat = 12
        var frame: CGRect?
        if axis == .vertical {
            let h = min(max(area.height, 220), vis.height - 2 * gap)
            let w: CGFloat = 170
            let y = min(max(area.maxY - h, vis.minY + gap), vis.maxY - gap - h)
            if area.maxX + gap + w <= vis.maxX - gap { frame = CGRect(x: area.maxX + gap, y: y, width: w, height: h) }
            else if area.minX - gap - w >= vis.minX + gap { frame = CGRect(x: area.minX - gap - w, y: y, width: w, height: h) }
        } else {
            let h: CGFloat = 150
            let w = min(max(area.width, 260), vis.width - 2 * gap)
            let x = min(max(area.minX, vis.minX + gap), vis.maxX - gap - w)
            let below = CGRect(x: x, y: area.minY - gap - h, width: w, height: h)
            let above = CGRect(x: x, y: area.maxY + gap, width: w, height: h)
            for c in [below, above] where vis.contains(c) && !c.intersects(controls) { frame = c; break }
        }
        guard let frame else { panel.orderOut(nil); return }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}
