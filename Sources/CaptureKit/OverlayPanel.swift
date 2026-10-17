import AppKit
import ShotcraftCore

/// Window level of the selection overlay: above the menu bar, Dock and floating panels, but one below
/// pop-up menus so the aspect-ratio menu can open on top of it.
let overlayWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

/// Full-screen, borderless, non-activating panel for one display (CleanShot: `FSWindow`). It can become key
/// without activating Shotcraft, so the frontmost app keeps its active look while we receive keys.
@MainActor
final class OverlayPanel: NSPanel {
    let overlayView: OverlayView
    let overlayScreenFrame: CGRect

    init(screen: NSScreen, session: SelectionSession, frozen: CGImage?) {
        overlayScreenFrame = screen.frame
        overlayView = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), session: session,
                                  screenFrame: screen.frame, scale: screen.backingScaleFactor)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = overlayWindowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isMovable = false
        becomesKeyOnlyIfNeeded = false

        // Root view holds the frozen screenshot as layer contents; the overlay view draws on top.
        let root = NSView(frame: overlayView.frame)
        root.wantsLayer = true
        if let frozen {
            root.layer?.contents = frozen
            root.layer?.contentsGravity = .resize
        }
        overlayView.autoresizingMask = [.width, .height]
        root.addSubview(overlayView)
        contentView = root
        setFrame(screen.frame, display: false)
        initialFirstResponder = overlayView
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Esc that reaches the window (e.g. from a control) cancels the session.
    override func cancelOperation(_ sender: Any?) { overlayView.session?.cancel() }

    /// True when `globalPoint` is over an interactive control rather than the overlay itself.
    func isOverControl(_ globalPoint: CGPoint) -> Bool {
        let local = CGPoint(x: globalPoint.x - overlayScreenFrame.minX, y: globalPoint.y - overlayScreenFrame.minY)
        // The content view sits at the window origin, so `local` is in the overlay's superview coordinates.
        guard let hit = overlayView.hitTest(local) else { return false }
        return hit !== overlayView
    }

    func tearDown() {
        overlayView.session = nil
        orderOut(nil)
        close()
    }
}

/// Draws the curtain, selection, handles, dimensions, hovered window, crosshair and magnifier for one
/// screen, and forwards input (in global Cocoa coordinates) to the session.
@MainActor
final class OverlayView: NSView {
    weak var session: SelectionSession?
    let screenFrame: CGRect
    let scale: CGFloat
    private var tracking: NSTrackingArea?

    init(frame: CGRect, session: SelectionSession, screenFrame: CGRect, scale: CGFloat) {
        self.session = session
        self.screenFrame = screenFrame
        self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: Input

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) { session?.mouseMoved(to: globalPoint(event)) }
    override func mouseEntered(with event: NSEvent) { session?.mouseMoved(to: globalPoint(event)) }
    override func cursorUpdate(with event: NSEvent) { session?.mouseMoved(to: globalPoint(event)) }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        session?.mouseDown(at: globalPoint(event), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) { session?.mouseDragged(to: globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { session?.mouseUp(at: globalPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { session?.rightMouseDown() }
    override func keyDown(with event: NSEvent) {
        if session?.keyDown(event) != true { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) { session?.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { session?.flagsChanged(event) }
    override func cancelOperation(_ sender: Any?) { session?.cancel() }

    // MARK: Drawing

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY) }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let selection = s.selection
        let hover = s.hoverRect
        let windowMode = s.mode == .window

        // Curtain with a hole for the selection or the hovered window.
        let hole: CGRect? = windowMode ? hover : (selection ?? hover)
        let dimAlpha: CGFloat = (selection == nil && hover == nil && !windowMode) ? 0.18 : 0.38
        ctx.saveGState()
        ctx.addRect(bounds)
        if let hole { ctx.addRect(local(hole)) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimAlpha).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if let hover, hole == hover {
            drawWindowHighlight(local(hover), tinted: windowMode, ctx: ctx)
            if windowMode, let info = s.hovered { drawWindowLabel(info, in: local(hover)) }
        }
        if let selection, !windowMode {
            drawSelection(local(selection), handles: s.isAdjustable && !s.isCreating, ctx: ctx)
            if s.config.showsDimensions && (s.isInteracting || (s.isAdjustable && s.config.style != .allInOne)) {
                drawDimensions(selection, ctx: ctx)
            }
        }
        if s.crosshair, !windowMode, !s.isAdjustable || selection == nil || s.isCreating {
            drawCrosshair(at: local(s.cursor), ctx: ctx)
        }
        if s.magnifier, !windowMode, screenFrame.contains(s.cursor), let image = s.pixels?.image(for: screenOrNil()),
           !(s.isAdjustable && selection != nil && !s.isCreating) {
            LoupeRenderer.draw(in: ctx, cursor: s.cursor, screenFrame: screenFrame, image: image, bounds: bounds)
        }
        if let hint = s.hintText, NSScreen.active.frame == screenFrame {
            drawPill(hint, center: CGPoint(x: bounds.midX, y: bounds.midY), font: .systemFont(ofSize: 14, weight: .medium))
        }
    }

    private func screenOrNil() -> NSScreen { NSScreen.screens.first { $0.frame == screenFrame } ?? NSScreen.active }

    private func drawSelection(_ r: CGRect, handles: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.stroke(r.insetBy(dx: -1, dy: -1))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        ctx.restoreGState()
        guard handles else { return }
        for h in SelectionHandle.allCases {
            let c = h.point(in: r)
            let size: CGFloat = h.isCorner ? 10 : 8
            let hr = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: hr)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: hr.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func drawWindowHighlight(_ r: CGRect, tinted: Bool, ctx: CGContext) {
        ctx.saveGState()
        if tinted {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
            ctx.fill(r)
        }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(tinted ? 3 : 2)
        ctx.stroke(r.insetBy(dx: 1.5, dy: 1.5))
        ctx.restoreGState()
    }

    private func drawWindowLabel(_ info: WindowInfo, in r: CGRect) {
        let name = info.title.isEmpty ? info.ownerName : "\(info.ownerName) — \(info.title)"
        let size = SelectionGeometry.dimensionString(info.cgFrame.size)
        drawPill("\(name)   \(size)", center: CGPoint(x: r.midX, y: r.midY), font: .systemFont(ofSize: 13, weight: .semibold))
    }

    private func drawDimensions(_ selection: CGRect, ctx: CGContext) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: selection.minX, y: selection.minY)) } ?? screenOrNil()
        var text = SelectionGeometry.dimensionString(selection.size)
        let px = screen.backingScaleFactor
        if px != 1 {
            text += "  ·  " + SelectionGeometry.dimensionString(CGSize(width: selection.width * px, height: selection.height * px)) + " px"
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pill = CGSize(width: textSize.width + 16, height: textSize.height + 8)
        // Below the bottom-left corner, or inside when there is no room.
        var origin = CGPoint(x: selection.minX, y: selection.minY - pill.height - 6)
        if origin.y < screen.frame.minY + 2 { origin.y = selection.minY + 6 }
        origin.x = min(max(origin.x, screen.frame.minX + 2), screen.frame.maxX - pill.width - 2)
        let r = local(CGRect(origin: origin, size: pill))
        guard r.intersects(bounds) else { return }
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 8, y: r.minY + 4), withAttributes: attrs)
    }

    private func drawCrosshair(at p: CGPoint, ctx: CGContext) {
        guard bounds.insetBy(dx: -1, dy: -1).contains(p) else { return }
        ctx.saveGState()
        for (color, width) in [(NSColor.black.withAlphaComponent(0.45), CGFloat(3)), (NSColor.white.withAlphaComponent(0.9), CGFloat(1))] {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.move(to: CGPoint(x: bounds.minX, y: p.y.rounded() + 0.5))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: p.y.rounded() + 0.5))
            ctx.move(to: CGPoint(x: p.x.rounded() + 0.5, y: bounds.minY))
            ctx.addLine(to: CGPoint(x: p.x.rounded() + 0.5, y: bounds.maxY))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawPill(_ text: String, center: CGPoint, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let maxWidth = bounds.width - 40
        let w = min(size.width + 28, maxWidth), h = size.height + 16
        let r = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        let path = NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        let textRect = CGRect(x: r.minX + 14, y: r.minY + 8, width: w - 28, height: size.height)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        var a = attrs
        a[.paragraphStyle] = para
        (text as NSString).draw(in: textRect, withAttributes: a)
    }
}

/// The magnifier (CleanShot: `Loupe` – `pixelZoom`, `pixelCount`): a zoomed pixel grid around the cursor
/// with the screen coordinates and the hex color of the center pixel.
@MainActor
enum LoupeRenderer {
    static let pixelCount = 15
    static let pixelZoom: CGFloat = 8

    static func draw(in ctx: CGContext, cursor: CGPoint, screenFrame: CGRect, image: CGImage, bounds: CGRect) {
        let k = CGFloat(image.width) / screenFrame.width
        let px = Int(((cursor.x - screenFrame.minX) * k).rounded(.down))
        let py = Int(((screenFrame.maxY - cursor.y) * k).rounded(.down))
        let n = pixelCount, half = n / 2
        guard let sample = ImageTools.context(width: n, height: n) else { return }
        sample.setFillColor(CGColor(gray: 0, alpha: 1))
        sample.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let region = CGRect(x: px - half, y: py - half, width: n, height: n)
        let visible = region.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isNull, let part = image.cropping(to: visible) {
            // `region` is top-left based; the sample context is bottom-left based.
            let x = visible.minX - region.minX
            let y = CGFloat(n) - (visible.minY - region.minY) - visible.height
            sample.interpolationQuality = .none
            sample.draw(part, in: CGRect(x: x, y: y, width: visible.width, height: visible.height))
        }
        var hex = "#000000"
        if let data = sample.data {
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            let i = half * sample.bytesPerRow + half * 4
            hex = SelectionGeometry.hexString(r: Double(bytes[i]) / 255, g: Double(bytes[i + 1]) / 255, b: Double(bytes[i + 2]) / 255)
        }
        guard let zoomed = sample.makeImage() else { return }

        let side = CGFloat(n) * pixelZoom
        let labelHeight: CGFloat = 22
        let total = CGSize(width: side, height: side + labelHeight + 4)
        let lp = CGPoint(x: cursor.x - screenFrame.minX, y: cursor.y - screenFrame.minY)
        var origin = CGPoint(x: lp.x + 24, y: lp.y - 24 - total.height)
        if origin.x + total.width > bounds.maxX - 4 { origin.x = lp.x - 24 - total.width }
        if origin.y < bounds.minY + 4 { origin.y = lp.y + 24 }
        let grid = CGRect(x: origin.x, y: origin.y + labelHeight + 4, width: side, height: side)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: CGColor(gray: 0, alpha: 0.5))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(CGPath(roundedRect: grid, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: grid, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(zoomed, in: grid)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.setLineWidth(0.5)
        for i in 1..<n {
            let o = CGFloat(i) * pixelZoom
            ctx.move(to: CGPoint(x: grid.minX + o, y: grid.minY)); ctx.addLine(to: CGPoint(x: grid.minX + o, y: grid.maxY))
            ctx.move(to: CGPoint(x: grid.minX, y: grid.minY + o)); ctx.addLine(to: CGPoint(x: grid.maxX, y: grid.minY + o))
        }
        ctx.strokePath()
        let center = CGRect(x: grid.minX + CGFloat(half) * pixelZoom, y: grid.minY + CGFloat(half) * pixelZoom,
                            width: pixelZoom, height: pixelZoom)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        ctx.stroke(center.insetBy(dx: -1, dy: -1))
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.stroke(center.insetBy(dx: -0.5, dy: -0.5))
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: grid.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.strokePath()

        // Coordinates are shown in points relative to the screen's top-left, like the system tools.
        let coords = "\(Int(cursor.x - screenFrame.minX)), \(Int(screenFrame.maxY - cursor.y))"
        let text = "\(coords)   \(hex)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let label = CGRect(x: origin.x, y: origin.y, width: side, height: labelHeight)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: label, xRadius: 6, yRadius: 6).fill()
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: label.midX - size.width / 2, y: label.midY - size.height / 2), withAttributes: attrs)
    }
}
