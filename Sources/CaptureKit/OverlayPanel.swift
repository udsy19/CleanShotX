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
        // Explicitly false: otherwise AppKit passes clicks through fully transparent pixels of a non-opaque window,
        // e.g. the undimmed hole over a hovered window, and the click lands in the app underneath.
        ignoresMouseEvents = false
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

        // Curtain (black ~38%) with a full-brightness hole for the selection or the hovered window.
        let hole: CGRect? = windowMode ? hover : (selection ?? hover)
        ctx.saveGState()
        ctx.addRect(bounds)
        if let hole { ctx.addRect(local(hole)) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(OverlayStyle.dimAlpha).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if windowMode, let hover, let info = s.hovered {
            let name = info.ownerName.isEmpty ? info.title : info.ownerName
            if !name.isEmpty { drawWindowName(name, in: local(hover)) }
        }
        if let selection, !windowMode {
            drawSelection(local(selection), handles: s.isAdjustable && !s.isCreating, brackets: s.isRecordingPurpose, ctx: ctx)
            if s.showsDimensionBadge { drawDimensionBadge(selection) }
        }
        let guides = !windowMode && (!s.isAdjustable || selection == nil || s.isCreating)
        if guides, s.showsCrosshair {
            drawCrosshair(at: local(s.cursor), ctx: ctx)
            if screenFrame.contains(s.cursor) {
                let coords = OverlayStyle.coordinates(of: s.cursor, on: screenFrame)
                if s.showsMagnifier, let screen = screenOrNil(), let image = s.pixels?.image(for: screen) {
                    LoupeRenderer.draw(in: ctx, cursor: s.cursor, screenFrame: screenFrame, image: image, bounds: bounds, coordinates: coords)
                } else {
                    drawCoordinates(coords, near: local(s.cursor))
                }
            }
        }
        if let hint = s.hintText, NSScreen.active.frame == screenFrame { drawHint(hint) }
    }

    private func screenOrNil() -> NSScreen? { NSScreen.screens.first { $0.frame == screenFrame } }

    private func drawSelection(_ r: CGRect, handles: Bool, brackets: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.stroke(r.insetBy(dx: -1.5, dy: -1.5))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        ctx.restoreGState()

        if brackets {
            // Record mode: white L-shaped corner brackets just outside the rect.
            let o = r.insetBy(dx: -4, dy: -4), arm: CGFloat = 14
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            for (x, y, sx, sy) in [(o.minX, o.minY, 1.0, 1.0), (o.maxX, o.minY, -1.0, 1.0), (o.minX, o.maxY, 1.0, -1.0), (o.maxX, o.maxY, -1.0, -1.0)] {
                ctx.move(to: CGPoint(x: x + sx * arm, y: y))
                ctx.addLine(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x, y: y + sy * arm))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        guard handles else { return }
        // Small white pills on the edge midpoints, rounded squares on the corners.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        for h in SelectionHandle.allCases {
            let c = h.point(in: r)
            let size: CGSize
            if h.isCorner { size = CGSize(width: 8, height: 8) }
            else if h == .top || h == .bottom { size = CGSize(width: 14, height: 4) }
            else { size = CGSize(width: 4, height: 14) }
            let hr = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
            ctx.addPath(CGPath(roundedRect: hr, cornerWidth: 2, cornerHeight: 2, transform: nil))
        }
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Dark-grey "W x H" badge above the selection's top-left corner (inside it when there is no room).
    private func drawDimensionBadge(_ selection: CGRect) {
        let corner = CGPoint(x: selection.minX, y: selection.maxY)
        let screen = NSScreen.screens.first { NSMouseInRect(corner, $0.frame, false) } ?? screenShowingMost(of: selection)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let text = SelectionGeometry.dimensionString(selection.size, separator: " x ") as NSString
        let textSize = text.size(withAttributes: attrs)
        let pill = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 6)
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + pill.height > screen.frame.maxY - 2 { origin.y = selection.maxY - pill.height - 6 }
        origin.x = min(max(origin.x, screen.frame.minX + 2), screen.frame.maxX - pill.width - 2)
        origin.y = max(origin.y, screen.frame.minY + 2)
        let r = local(CGRect(origin: origin, size: pill))
        guard r.intersects(bounds) else { return }
        OverlayStyle.badgeFill.setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: attrs)
    }

    /// Thin full-length guide lines (black ~50% with a light halo).
    private func drawCrosshair(at p: CGPoint, ctx: CGContext) {
        guard bounds.insetBy(dx: -1, dy: -1).contains(p) else { return }
        let x = p.x.rounded(.down) + 0.5, y = p.y.rounded(.down) + 0.5
        ctx.saveGState()
        for (color, width) in [(NSColor.white.withAlphaComponent(0.3), CGFloat(3)), (NSColor.black.withAlphaComponent(0.5), CGFloat(1))] {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.move(to: CGPoint(x: bounds.minX, y: y)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
            ctx.move(to: CGPoint(x: x, y: bounds.minY)); ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// X over Y, right-aligned small monospaced text just below-right of the cursor (flips at screen edges).
    private func drawCoordinates(_ coords: (x: String, y: String), near p: CGPoint) {
        let attrs = OverlayStyle.coordinateAttributes(alignment: .right)
        let line = max((coords.x as NSString).size(withAttributes: attrs).width, (coords.y as NSString).size(withAttributes: attrs).width)
        let size = CGSize(width: ceil(line) + 2, height: 28)
        var r = CGRect(x: p.x + 10, y: p.y - 10 - size.height, width: size.width, height: size.height)
        if r.maxX > bounds.maxX - 2 { r.origin.x = p.x - 10 - size.width }
        if r.minY < bounds.minY + 2 { r.origin.y = p.y + 10 }
        ("\(coords.x)\n\(coords.y)" as NSString).draw(in: r, withAttributes: attrs)
    }

    /// Centred light instruction pill.
    private func drawHint(_ text: String) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: para,
                                                    .foregroundColor: NSColor.black.withAlphaComponent(0.85)]
        let size = (text as NSString).size(withAttributes: attrs)
        let h: CGFloat = 32
        let w = min(ceil(size.width) + 32, bounds.width - 40)
        let r = CGRect(x: (bounds.midX - w / 2).rounded(), y: (bounds.midY - h / 2).rounded(), width: w, height: h)
        let path = NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        shadow.set()
        NSColor.white.withAlphaComponent(0.88).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (text as NSString).draw(in: CGRect(x: r.minX + 16, y: r.midY - size.height / 2, width: w - 32, height: size.height), withAttributes: attrs)
    }

    /// Dark app-name pill centred on the hovered window (CleanShot: `windowNameLabel`).
    private func drawWindowName(_ name: String, in r: CGRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium),
                                                    .foregroundColor: NSColor.white, .paragraphStyle: para]
        let size = (name as NSString).size(withAttributes: attrs)
        let h: CGFloat = 34
        let w = min(ceil(size.width) + 36, max(r.width - 16, 60))
        let pill = CGRect(x: (r.midX - w / 2).rounded(), y: (r.midY - h / 2).rounded(), width: w, height: h)
        OverlayStyle.namePillFill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
        (name as NSString).draw(in: CGRect(x: pill.minX + 18, y: pill.midY - size.height / 2, width: w - 36, height: size.height), withAttributes: attrs)
    }
}

/// Overlay design tokens (ui-reference §0.1 / §2).
@MainActor
enum OverlayStyle {
    static let dimAlpha: CGFloat = 0.38
    static let badgeFill = NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.85)
    static let namePillFill = NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 0.9)

    /// Cursor position in points from the screen's top-left, like the system tools.
    static func coordinates(of p: CGPoint, on screenFrame: CGRect) -> (x: String, y: String) {
        (String(Int((p.x - screenFrame.minX).rounded(.down))), String(Int((screenFrame.maxY - p.y).rounded(.down))))
    }

    /// Small dark monospaced digits with a light halo, readable on any background.
    static func coordinateAttributes(alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        let halo = NSShadow()
        halo.shadowColor = NSColor.white.withAlphaComponent(0.9)
        halo.shadowBlurRadius = 2
        halo.shadowOffset = .zero
        return [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.black.withAlphaComponent(0.85), .shadow: halo, .paragraphStyle: para]
    }
}

/// The magnifier (CleanShot: `Loupe` – `pixelZoom`, `pixelCount`): a rounded square of nearest-neighbour
/// pixels around the cursor with a darker crosshair band, and the coordinates just above it.
@MainActor
enum LoupeRenderer {
    static let pixelCount = 11
    static let pixelZoom: CGFloat = 6
    static let offset: CGFloat = 12

    static func draw(in ctx: CGContext, cursor: CGPoint, screenFrame: CGRect, image: CGImage, bounds: CGRect,
                     coordinates: (x: String, y: String)) {
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
        guard let zoomed = sample.makeImage() else { return }

        let side = CGFloat(n) * pixelZoom
        let text = "\(coordinates.x), \(coordinates.y)" as NSString
        let attrs = OverlayStyle.coordinateAttributes(alignment: .center)
        let labelHeight = ceil(text.size(withAttributes: attrs).height)
        let total = CGSize(width: side, height: side + labelHeight + 2)
        let lp = CGPoint(x: cursor.x - screenFrame.minX, y: cursor.y - screenFrame.minY)
        var origin = CGPoint(x: lp.x + offset, y: lp.y - offset - total.height)
        if origin.x + total.width > bounds.maxX - 4 { origin.x = lp.x - offset - total.width }
        if origin.y < bounds.minY + 4 { origin.y = lp.y + offset }
        let grid = CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: side, height: side)
        let shape = CGPath(roundedRect: grid, cornerWidth: 8, cornerHeight: 8, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(zoomed, in: grid)
        // Darker translucent band through the centre row and column, then the centre pixel outline.
        let c = CGFloat(half) * pixelZoom
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.22))
        ctx.fill(CGRect(x: grid.minX + c, y: grid.minY, width: pixelZoom, height: c))
        ctx.fill(CGRect(x: grid.minX + c, y: grid.minY + c + pixelZoom, width: pixelZoom, height: side - c - pixelZoom))
        ctx.fill(CGRect(x: grid.minX, y: grid.minY + c, width: c, height: pixelZoom))
        ctx.fill(CGRect(x: grid.minX + c + pixelZoom, y: grid.minY + c, width: side - c - pixelZoom, height: pixelZoom))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: grid.minX + c, y: grid.minY + c, width: pixelZoom, height: pixelZoom).insetBy(dx: -0.5, dy: -0.5))
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: grid.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
        ctx.strokePath()

        text.draw(in: CGRect(x: grid.minX - 20, y: grid.maxY + 2, width: side + 40, height: labelHeight), withAttributes: attrs)
    }
}
