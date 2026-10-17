import AppKit
import ShotcraftCore

/// The single renderer for an Annotate composition. The canvas view and every export path call `draw`,
/// which guarantees WYSIWYG output. The context must be in *output points*, y-down, origin top-left.
final class AnnotateRenderer {
    let effects = EffectCache()
    let images = ImageObjectCache()
    let wallpapers = WallpaperCache()
    /// Path of the desktop wallpaper to use for `.desktop` fills (supplied by the editor window).
    var desktopWallpaperPath: () -> String? = {
        guard let s = NSScreen.main, let u = NSWorkspace.shared.desktopImageURL(for: s) else { return nil }
        return u.path
    }

    struct Options {
        var drawBackground = true
        /// Clip annotations to the content bounds (export). The live canvas disables this while the user
        /// draws outside the image so the auto-expanding canvas doesn't hide the stroke mid-drag.
        var clipToContent = true
        /// Object being edited inline (text) — the text view draws it instead.
        var hiddenObjectID: UUID?
        /// Object being drawn, not yet committed.
        var extraObject: Annotation?
    }

    // MARK: Export

    /// Renders the composition at the base image's pixel density (Retina screenshots keep full resolution).
    func export(_ s: CanvasState, layout: CompositionLayout) -> CGImage? {
        let sc = s.scale
        let w = max(1, Int((layout.outputSize.width * sc).rounded())), h = max(1, Int((layout.outputSize.height * sc).rounded()))
        guard let ctx = ImageTools.context(width: w, height: h, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: sc, y: -sc)
        ctx.interpolationQuality = .high
        draw(s, layout: layout, in: ctx, options: Options())
        return ctx.makeImage()
    }

    /// Annotations + base image only (no background, no crop) at full resolution — used to flatten.
    func flattenedContent(_ s: CanvasState) -> CGImage? {
        var copy = s
        copy.background = BackgroundSettings()
        copy.cropRect = nil
        let layout = CompositionLayout.make(contentBounds: s.imageRect, background: copy.background, scale: s.scale)
        return export(copy, layout: layout)
    }

    // MARK: Drawing

    func draw(_ s: CanvasState, layout: CompositionLayout, in ctx: CGContext, options: Options) {
        let bg = s.background
        let bgActive = bg.isActive && options.drawBackground
        if bgActive { drawFill(bg, in: CGRect(origin: .zero, size: layout.outputSize), ctx: ctx) }

        let radius = bgActive ? CGFloat(max(0, bg.cornerRadius)) : 0
        let shadowAmount = bgActive ? CGFloat(max(0, min(1, bg.shadow))) : 0
        ctx.saveGState()
        if shadowAmount > 0.001 {
            let (ds, flip) = deviceMetrics(ctx)
            ctx.setShadow(offset: CGSize(width: 0, height: flip * 8 * shadowAmount * ds), blur: 44 * shadowAmount * ds,
                          color: CGColor(gray: 0, alpha: 0.18 + 0.4 * shadowAmount))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if bgActive {
            let frame = CGPath(roundedRect: layout.frameRect, cornerWidth: min(radius, layout.frameRect.width / 2),
                               cornerHeight: min(radius, layout.frameRect.height / 2), transform: nil)
            ctx.addPath(frame)
            ctx.clip()
            if bg.inset > 0 {
                ctx.setFillColor(ImageAnalysis.cornerColor(of: s.image).cgColor)
                ctx.fill(layout.frameRect)
            }
        }
        let clip = options.clipToContent || bgActive
        if clip { ctx.clip(to: layout.contentRect) }
        let d = layout.documentToOutput
        ctx.translateBy(x: d.dx, y: d.dy)
        drawContent(s, bounds: layout.contentBounds, in: ctx, options: options)
        if shadowAmount > 0.001 { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    /// Base image, effects and annotations in document coordinates.
    private func drawContent(_ s: CanvasState, bounds: CGRect, in ctx: CGContext, options: Options) {
        drawImage(s.image, in: s.imageRect, ctx: ctx)

        var objects = s.objects.filter { $0.id != options.hiddenObjectID }
        if let extra = options.extraObject { objects.append(extra) }

        for a in objects where a.kind == .pixelate { drawPixelate(a, s, ctx) }

        let spots = objects.filter { $0.kind == .spotlight && $0.frame.width > 0.5 && $0.frame.height > 0.5 }
        if !spots.isEmpty {
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(max(0, min(1, s.spotlightOpacity)))))
            ctx.fill(bounds.union(s.imageRect).insetBy(dx: -4000, dy: -4000))
            ctx.setBlendMode(.clear)
            for sp in spots {
                if sp.spotlightShape == .ellipse { ctx.fillEllipse(in: sp.frame) }
                else {
                    let r = sp.frame
                    let rad = min(6, r.width / 2, r.height / 2)
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
                    ctx.fillPath()
                }
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        for a in objects where a.kind != .pixelate && a.kind != .spotlight { drawObject(a, ctx) }
    }

    /// Scale from user space to device pixels, and the sign that makes a shadow fall *down* on screen.
    private func deviceMetrics(_ ctx: CGContext) -> (CGFloat, CGFloat) {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(0.01, hypot(t.a, t.b))
        return (scale, t.d < 0 ? -1 : 1)
    }

    func drawObject(_ a: Annotation, _ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let wantsShadow = a.shadow && a.kind != .highlighter
        let translucent = a.color.a < 0.999 && (a.kind == .arrow)
        if wantsShadow {
            let (ds, flip) = deviceMetrics(ctx)
            ctx.setShadow(offset: CGSize(width: 0, height: flip * 1.5 * ds), blur: 5 * ds, color: CGColor(gray: 0, alpha: 0.45))
        }
        if wantsShadow || translucent { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        defer { if wantsShadow || translucent { ctx.endTransparencyLayer() } }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let color = a.color.cgColor
        switch a.kind {
        case .rectangle:
            let r = a.frame
            let rad = min(a.lineWidth * 0.8, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.setStrokeColor(color); ctx.setLineWidth(a.lineWidth); ctx.strokePath()
        case .filledRectangle:
            let r = a.frame
            let rad = min(4, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.setFillColor(color); ctx.fillPath()
        case .ellipse:
            ctx.setStrokeColor(color); ctx.setLineWidth(a.lineWidth); ctx.strokeEllipse(in: a.frame)
        case .line:
            ctx.move(to: a.start); ctx.addLine(to: a.end)
            ctx.setStrokeColor(color); ctx.setLineWidth(a.lineWidth); ctx.strokePath()
        case .arrow:
            let (tail, tip) = a.inverseArrow ? (a.end, a.start) : (a.start, a.end)
            let g = ArrowGenerator.geometry(tail: tail, tip: tip, control: a.control, width: a.lineWidth, style: a.arrowStyle)
            let opaque = a.color.withAlpha(1).cgColor
            if translucent { ctx.setAlpha(CGFloat(a.color.a)) }
            ctx.setStrokeColor(opaque); ctx.setFillColor(opaque)
            for s in g.strokes { ctx.addPath(s.path); ctx.setLineWidth(s.width); ctx.strokePath() }
            for f in g.fills { ctx.addPath(f); ctx.fillPath() }
        case .pen:
            ctx.addPath(PathSmoothing.path(a.points, smooth: a.smooth))
            ctx.setStrokeColor(color); ctx.setLineWidth(a.lineWidth); ctx.strokePath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            let c = a.color.withAlpha(a.opacity).cgColor
            if a.highlightShape == .rectangle {
                ctx.setFillColor(c); ctx.fill(a.frame)
            } else {
                ctx.addPath(PathSmoothing.path(a.points, smooth: a.smooth))
                ctx.setLineCap(.butt)
                ctx.setStrokeColor(c); ctx.setLineWidth(a.highlighterWidth); ctx.strokePath()
            }
        case .text:
            drawText(a, ctx)
        case .counter:
            drawCounter(a, ctx)
        case .image:
            if let img = images.image(for: a) {
                ctx.setAlpha(CGFloat(a.opacity))
                drawImage(img, in: a.frame, ctx: ctx)
            }
        case .pixelate, .spotlight:
            break
        }
    }

    private func drawPixelate(_ a: Annotation, _ s: CanvasState, _ ctx: CGContext) {
        let r = Geo.pixelAligned(a.frame, scale: s.scale)
        guard r.width > 0.5, r.height > 0.5 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if a.pixelateStyle == .blackOut {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(r)
            return
        }
        let visible = r.intersection(s.imageRect)
        guard !visible.isNull, let img = effects.processed(s.image, style: a.pixelateStyle, intensity: a.intensity, scale: s.scale) else { return }
        ctx.clip(to: visible)
        drawImage(img, in: s.imageRect, ctx: ctx)
    }

    private func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawText(_ a: Annotation, _ ctx: CGContext) {
        let frame = a.frame
        let pad = TextLayout.padding(a)
        if a.textStyle.hasBox {
            let rad = min(a.fontSize * 0.3, frame.height / 2)
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
        }
        let textRect = frame.insetBy(dx: pad, dy: pad)
        withAppKit(ctx) {
            if a.textStyle == .outline {
                var attrs = TextLayout.attributes(a)
                attrs[.strokeColor] = NSColor(srgbRed: a.color.r, green: a.color.g, blue: a.color.b, alpha: a.color.a)
                attrs[.strokeWidth] = 22.0
                NSAttributedString(string: a.text, attributes: attrs)
                    .draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            NSAttributedString(string: a.text, attributes: TextLayout.attributes(a))
                .draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    private func drawCounter(_ a: Annotation, _ ctx: CGContext) {
        let r = a.frame
        ctx.setFillColor(a.color.cgColor)
        ctx.fillEllipse(in: r)
        let label = a.counterStyle.label(a.number)
        let fc = a.color.contrasting
        var size = r.height * 0.5
        if label.count > 2 { size *= 2.2 / CGFloat(label.count) }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(4, size), weight: .bold),
            .foregroundColor: NSColor(srgbRed: fc.r, green: fc.g, blue: fc.b, alpha: 1),
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let b = str.size()
        withAppKit(ctx) {
            str.draw(at: CGPoint(x: r.midX - b.width / 2, y: r.midY - b.height / 2))
        }
    }

    /// Draws a CGImage into a y-down context without flipping it.
    func drawImage(_ img: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    // MARK: Background fills

    func drawFill(_ bg: BackgroundSettings, in rect: CGRect, ctx: CGContext) {
        switch bg.fill {
        case .none: break
        case .color(let c):
            ctx.setFillColor(c.cgColor); ctx.fill(rect)
        case .gradient(let id):
            drawGradient(GradientPreset.named(id) ?? GradientPreset.all[0], in: rect, ctx: ctx)
        case .desktop:
            if let p = desktopWallpaperPath(), let img = wallpapers.image(path: p) { aspectFill(img, rect, ctx) }
            else if let d = bg.embeddedImage, let img = wallpapers.image(data: d) { aspectFill(img, rect, ctx) }
            else { drawGradient(GradientPreset.all[0], in: rect, ctx: ctx) }
        case .image(let path):
            if let img = wallpapers.image(path: path) { aspectFill(img, rect, ctx) }
            else if let d = bg.embeddedImage, let img = wallpapers.image(data: d) { aspectFill(img, rect, ctx) }
            else { drawGradient(GradientPreset.all[0], in: rect, ctx: ctx) }
        }
    }

    func drawGradient(_ g: GradientPreset, in rect: CGRect, ctx: CGContext) {
        let colors = g.colors.map(\.cgColor) as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
        let th = g.angle * .pi / 180
        let dx = cos(th), dy = sin(th)
        let half = abs(rect.width / 2 * dx) + abs(rect.height / 2 * dy)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(grad, start: CGPoint(x: c.x - dx * half, y: c.y - dy * half),
                               end: CGPoint(x: c.x + dx * half, y: c.y + dy * half),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private func aspectFill(_ img: CGImage, _ rect: CGRect, _ ctx: CGContext) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = max(rect.width / iw, rect.height / ih)
        let w = iw * s, h = ih * s
        ctx.saveGState()
        ctx.clip(to: rect)
        drawImage(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), ctx: ctx)
        ctx.restoreGState()
    }
}

/// UI-free rendering entry point: flattens a document exactly like the editor's export
/// (used by the self-tests; usable by other code that holds a `CanvasState`).
public enum AnnotateComposer {
    public static func render(_ state: CanvasState, expandCanvas: Bool = true) -> CGImage? {
        let opaque = state.background.isActive && state.background.autoBalance ? ImageAnalysis.opaqueBounds(of: state.image) : nil
        return AnnotateRenderer().export(state, layout: state.layout(expand: expandCanvas, opaqueBounds: opaque))
    }
}
