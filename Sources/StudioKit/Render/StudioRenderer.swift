import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Immutable snapshot of everything needed to draw a frame. Rebuilt on the main thread after each edit and
/// swapped atomically into `SceneBox`, so the render queue never sees a half-applied change.
final class RenderScene: @unchecked Sendable {
    let style: StudioStyle
    let zooms: [ZoomSegment]
    let cameraFullscreen: [TimeSegment]
    let sourceSize: CGSize
    let recordingScale: Double
    let cursor: CursorTrack
    let keystrokes: KeystrokeTimeline
    let planner: ZoomPlanner
    let packageURL: URL

    init(project: StudioProject, events: StudioEvents, packageURL: URL, reuse previous: RenderScene? = nil) {
        style = project.style
        zooms = project.zooms
        cameraFullscreen = project.cameraFullscreen.sorted { $0.start < $1.start }
        sourceSize = project.recording.pixelSize
        recordingScale = project.recording.scale
        self.packageURL = packageURL
        // Smoothing the cursor is the only costly part; reuse it while the amount is unchanged.
        if let previous, previous.style.cursor.smoothing == project.style.cursor.smoothing {
            cursor = previous.cursor
        } else {
            cursor = CursorTrack(events: events, smoothing: project.style.cursor.smoothing)
        }
        if let previous, previous.style.keystrokes.displayAll == project.style.keystrokes.displayAll {
            keystrokes = previous.keystrokes
        } else {
            keystrokes = KeystrokeTimeline(keys: events.keys, displayAll: project.style.keystrokes.displayAll)
        }
        planner = ZoomPlanner(segments: project.zooms, animation: project.style.zoom.animation, easing: project.style.zoom.easing)
    }

    func layout(for canvas: CGSize) -> CanvasLayout { CanvasLayout(sourceSize: sourceSize, style: style, canvasSize: canvas) }

    func viewport(at t: Double, layout: CanvasLayout) -> Viewport {
        planner.viewport(at: t) { seg, time in
            let p = seg.mode == .followCursor ? (self.cursor.cameraPosition(at: time) ?? seg.focus) : seg.focus
            return layout.canvasNormalized(p.clamped)
        }
    }

    /// 0 = camera bubble, 1 = camera fills the canvas.
    func cameraFullscreenAmount(at t: Double) -> Double {
        let d = 0.4
        for s in cameraFullscreen where t >= s.start && t <= s.end {
            let len = min(d, (s.end - s.start) / 2)
            guard len > 0 else { return 1 }
            return min(Easing.apply(.smooth, (t - s.start) / len), Easing.apply(.smooth, (s.end - t) / len))
        }
        return 0
    }

    /// Camera rect on the canvas (bottom-left origin) at time t, nil when hidden.
    func cameraRect(at t: Double, layout: CanvasLayout, zoomScale: Double) -> (rect: CGRect, radius: CGFloat)? {
        let cam = style.camera
        guard cam.show else { return nil }
        let canvas = layout.canvasSize
        let short = min(canvas.width, canvas.height)
        let shrink = cam.shrinkOnZoom ? 1 - 0.3 * min(1, max(0, zoomScale - 1)) : 1
        let d = CGFloat(cam.size) * short * CGFloat(shrink)
        let m = 0.035 * short
        let x: CGFloat = (cam.position == .topLeft || cam.position == .bottomLeft) ? m : canvas.width - m - d
        let y: CGFloat = (cam.position == .bottomLeft || cam.position == .bottomRight) ? m : canvas.height - m - d
        let bubble = CGRect(x: x, y: y, width: d, height: d)
        let r0: CGFloat = switch cam.shape {
        case .circle: d / 2
        case .rounded: d * 0.22
        case .square: d * 0.05
        }
        let f = CGFloat(cameraFullscreenAmount(at: t))
        guard f > 0 else { return (bubble, r0) }
        let full = CGRect(origin: .zero, size: canvas)
        func l(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * f }
        return (CGRect(x: l(bubble.minX, full.minX), y: l(bubble.minY, full.minY),
                       width: l(bubble.width, full.width), height: l(bubble.height, full.height)), l(r0, 0))
    }
}

/// Thread-safe holder of the current scene; the compositor reads it for every frame.
final class SceneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _scene: RenderScene
    init(_ scene: RenderScene) { _scene = scene }
    var scene: RenderScene {
        get { lock.lock(); defer { lock.unlock() }; return _scene }
        set { lock.lock(); _scene = newValue; lock.unlock() }
    }
}

/// The single render function shared by preview and export (FLCompositor / FLVideoPreviewController).
enum StudioRenderer {
    /// Composes one output frame.
    /// - Parameters:
    ///   - screen: decoded screen.mov frame (source pixels).
    ///   - camera: decoded camera.mov frame, if any.
    ///   - t: source time in seconds (events/zooms are on this timeline).
    ///   - canvas: output pixel size.
    static func render(scene: RenderScene, screen: CIImage?, camera: CIImage?, at t: Double, canvas: CGSize) -> CIImage {
        let layout = scene.layout(for: canvas)
        let style = scene.style
        let bounds = CGRect(origin: .zero, size: canvas)
        let viewport = scene.viewport(at: t, layout: layout)
        let zoom = layout.zoomTransform(viewport)
        let s = CGFloat(viewport.scale)

        // Background.
        var stage = background(style.background, scene: scene, bounds: bounds).transformed(by: zoom)

        // Screen with shadow and rounded corners.
        let screenRect = layout.screenRect.applying(zoom)
        let radius = CGFloat(style.effectiveCornerRadius) * layout.unit * s
        if style.effectiveShadow > 0 {
            let intensity = CGFloat(style.effectiveShadow)
            let blur = 36 * layout.unit * s * (0.4 + intensity)
            let shadowShape = roundedRect(screenRect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.75 * intensity))
                .transformed(by: CGAffineTransform(translationX: 0, y: -12 * layout.unit * s * intensity))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(blur / 2))
                .cropped(to: screenRect.insetBy(dx: -blur * 3, dy: -blur * 3))
            stage = shadowShape.composited(over: stage)
        }
        if let screen {
            var img = screen.cropped(to: layout.cropRect).transformed(by: layout.placement.concatenating(zoom))
            if radius > 0.5 {
                let mask = roundedRect(screenRect, radius: radius, color: .white)
                img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                         kCIInputMaskImageKey: mask])
            } else {
                img = img.cropped(to: screenRect)
            }
            stage = img.composited(over: stage)
        }

        // Cursor + click effects, drawn on the screen so they zoom with it.
        stage = drawCursor(scene: scene, layout: layout, zoom: zoom, zoomScale: s, at: t, over: stage)

        // Zoom motion blur while the viewport animates.
        if style.zoom.motionBlur > 0.01 {
            let next = scene.viewport(at: t + 1.0 / 60, layout: layout)
            let delta = abs(next.scale - viewport.scale) + Double(hypot(next.rect.midX - viewport.rect.midX, next.rect.midY - viewport.rect.midY)) * 2
            let amount = min(40, style.zoom.motionBlur * delta * 900)
            if amount > 0.5 {
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                stage = stage.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(cgPoint: center),
                                                                                          kCIInputAmountKey: amount]).cropped(to: bounds)
            }
        }
        stage = stage.cropped(to: bounds)

        // Camera bubble (not zoomed).
        if let camera, let (rect, r) = scene.cameraRect(at: t, layout: layout, zoomScale: viewport.scale) {
            stage = drawCamera(camera, in: rect, radius: r, flip: style.camera.flip, unit: layout.unit, over: stage)
        }

        // Keystrokes.
        if style.keystrokes.show, let (text, alpha) = scene.keystrokes.label(at: t), alpha > 0.01,
           let cg = Artwork.shared.label(text, fontSize: 30 * layout.unit * CGFloat(style.keystrokes.size)) {
            let img = CIImage(cgImage: cg)
            let m = 0.06 * canvas.height
            let y = style.keystrokes.position == .bottom ? m : canvas.height - m - img.extent.height
            let placed = img.transformed(by: CGAffineTransform(translationX: ((canvas.width - img.extent.width) / 2).rounded(), y: y.rounded()))
            stage = withAlpha(placed, alpha).composited(over: stage)
        }

        return stage.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
    }

    // MARK: Pieces

    static func background(_ bg: StudioBackground, scene: RenderScene, bounds: CGRect) -> CIImage {
        switch bg {
        case .none:
            return CIImage(color: .black).cropped(to: bounds)
        case .color(let c):
            return CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)).cropped(to: bounds)
        case .gradient(let preset):
            let cols = preset.colors
            let g = CIFilter.linearGradient()
            g.point0 = CGPoint(x: bounds.minX, y: bounds.maxY)
            g.point1 = CGPoint(x: bounds.maxX, y: bounds.minY)
            g.color0 = CIColor(red: cols[0].r, green: cols[0].g, blue: cols[0].b)
            g.color1 = CIColor(red: cols[1].r, green: cols[1].g, blue: cols[1].b)
            return (g.outputImage ?? CIImage(color: .black)).cropped(to: bounds)
        case .wallpaper(let path):
            return aspectFill(Artwork.shared.image(at: URL(fileURLWithPath: path)), bounds: bounds)
        case .image(let name):
            return aspectFill(Artwork.shared.image(at: scene.packageURL.appendingPathComponent(name)), bounds: bounds)
        }
    }

    static func aspectFill(_ cg: CGImage?, bounds: CGRect) -> CIImage {
        guard let cg else { return CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.14)).cropped(to: bounds) }
        let img = CIImage(cgImage: cg)
        let f = max(bounds.width / img.extent.width, bounds.height / img.extent.height)
        let w = img.extent.width * f, h = img.extent.height * f
        return img.transformed(by: CGAffineTransform(scaleX: f, y: f)
            .concatenating(CGAffineTransform(translationX: bounds.midX - w / 2, y: bounds.midY - h / 2))).cropped(to: bounds)
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(max(0, min(radius, min(rect.width, rect.height) / 2)))
        f.color = color
        return f.outputImage ?? CIImage.empty()
    }

    static func withAlpha(_ img: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return img }
        return img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, alpha)))])
    }

    static func disc(center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage {
        let g = CIFilter.radialGradient()
        g.center = center
        g.radius0 = Float(max(0, radius - 1))
        g.radius1 = Float(radius)
        g.color0 = color
        g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let r = radius + 2
        return (g.outputImage ?? .empty()).cropped(to: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    static func drawCursor(scene: RenderScene, layout: CanvasLayout, zoom: CGAffineTransform, zoomScale: CGFloat, at t: Double, over stage: CIImage) -> CIImage {
        let cs = scene.style.cursor
        var out = stage
        // Natural cursor ≈ 22pt tall on the recorded display.
        let base = 22 * CGFloat(scene.recordingScale) * layout.screenScale * zoomScale

        if cs.clickEffect == .ripple {
            let c = cs.rippleColor
            for (p, progress) in scene.cursor.ripples(at: t) where (0...1).contains(p.x) && (0...1).contains(p.y) {
                let center = layout.canvasPoint(p).applying(zoom)
                let e = Easing.apply(.snappy, progress)
                let r = base * CGFloat(0.35 + 1.15 * e) * CGFloat(max(0.8, cs.size * 0.8))
                let fade = (1 - progress)
                let outer = disc(center: center, radius: r, color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * 0.9 * fade))
                let inner = disc(center: center, radius: max(0, r - max(2, base * 0.12)), color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
                let fill = disc(center: center, radius: r, color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * 0.22 * fade))
                out = ring.composited(over: fill.composited(over: out))
            }
        }

        guard cs.show, let p = scene.cursor.position(at: t),
              p.x >= -0.01, p.x <= 1.01, p.y >= -0.01, p.y <= 1.01 else { return out }
        let alpha = scene.cursor.opacity(at: t, hideWhenIdle: cs.hideWhenIdle, hideWhenTyping: cs.hideWhenTyping)
        guard alpha > 0.01 else { return out }
        let press = cs.pressEffect ? scene.cursor.pressAmount(at: t) : 0
        let height = base * CGFloat(cs.size) * CGFloat(1 - 0.15 * press)
        guard height >= 4, let bmp = Artwork.shared.cursor(kind: scene.cursor.kind(at: t), style: cs.style, height: height) else { return out }
        // The bitmap is quantized; scale it to the exact size.
        let nominal = CGFloat(bmp.image.height)
        let quantH = max(8, (height / 4).rounded() * 4)
        let f = height / quantH
        let tip = layout.canvasPoint(p).applying(zoom)
        let img = CIImage(cgImage: bmp.image)
            .transformed(by: CGAffineTransform(translationX: -bmp.hotSpot.x, y: -(nominal - bmp.hotSpot.y))
                .concatenating(CGAffineTransform(scaleX: f, y: f))
                .concatenating(CGAffineTransform(translationX: tip.x, y: tip.y)))
        return withAlpha(img, alpha).composited(over: out)
    }

    static func drawCamera(_ camera: CIImage, in rect: CGRect, radius: CGFloat, flip: Bool, unit: CGFloat, over stage: CIImage) -> CIImage {
        var cam = camera.transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
        if flip { cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -cam.extent.width, y: 0)) }
        // Aspect-fill the target rect from the center of the camera frame.
        let src = cam.extent
        let f = max(rect.width / src.width, rect.height / src.height)
        let w = src.width * f, h = src.height * f
        cam = cam.transformed(by: CGAffineTransform(scaleX: f, y: f)
            .concatenating(CGAffineTransform(translationX: rect.midX - w / 2, y: rect.midY - h / 2)))
        let mask = roundedRect(rect, radius: radius, color: .white)
        let shaped = cam.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        let blur = 18 * unit
        let shadow = roundedRect(rect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            .transformed(by: CGAffineTransform(translationX: 0, y: -5 * unit))
            .clampedToExtent().applyingGaussianBlur(sigma: Double(blur / 2))
            .cropped(to: rect.insetBy(dx: -blur * 3, dy: -blur * 3))
        return shaped.composited(over: shadow.composited(over: stage))
    }
}
