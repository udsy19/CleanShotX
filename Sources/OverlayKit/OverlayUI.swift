import AppKit
import AVFoundation
import Carbon.HIToolbox
import QuickLookThumbnailing
import SuperScreenshotCore

// Shared building blocks for Quick Access cards, pins and the history window.

// MARK: - Window levels / behaviour

enum OverlayWindow {
    /// Pins float above normal windows; Quick Access cards above pins; the history strip and Quick Look on top.
    static let pinLevel = NSWindow.Level.floating
    static let quickAccessLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
    static let historyLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
    static let quickLookLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 4)
    static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    /// Borderless, transparent, non-activating panel that never steals focus from the frontmost app.
    static func makePanel(_ frame: NSRect, level: NSWindow.Level, canBecomeKey: Bool = false) -> OverlayPanel {
        let p = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.allowsKey = canBecomeKey
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = level
        p.collectionBehavior = behavior
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = !canBecomeKey
        p.isMovable = false
        p.animationBehavior = .none
        return p
    }
}

final class OverlayPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Visual constants shared by cards and pins (ui-reference §0.1, §4, §6).
enum OverlayStyle {
    /// Quick Access card corners (binary): 17 pt on macOS 26+, 15 pt before.
    static let cardCornerRadius: CGFloat =
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 17 : 15
    static let pinCornerRadius: CGFloat = 10
    /// Pin hover chrome fade (cards use `QuickAccessMotion.hoverFade`).
    static let hoverFade: TimeInterval = 0.12
    /// System "Reduce motion": slides become plain fades.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Crisp edge for cards: a hairline dark outline (keeps the card readable on light wallpapers) plus a 1 pt light
/// inner stroke (ui-reference §4: `rgba(255,255,255,0.2)`). Sits above all card content and never takes clicks.
final class CardStrokeView: NSView {
    private let inner = CALayer()

    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        inner.cornerRadius = radius - 0.5
        inner.cornerCurve = .continuous
        inner.borderWidth = 1
        inner.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.addSublayer(inner)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inner.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        CATransaction.commit()
    }
}

// MARK: - Temporary hotkeys while an overlay is hovered

/// Keyboard shortcuts for a hovered overlay are registered as global hotkeys only while the pointer is over it,
/// so they work without activating Super Screenshot (the frontmost app keeps focus).
@MainActor
final class HoverHotkeys {
    static let shared = HoverHotkeys()
    private var tokens: [UInt32] = []
    private weak var owner: AnyObject?

    struct Binding {
        let key: Int
        let modifiers: NSEvent.ModifierFlags
        let action: () -> Void
        init(_ key: Int, _ modifiers: NSEvent.ModifierFlags = [], _ action: @escaping () -> Void) {
            self.key = key; self.modifiers = modifiers; self.action = action
        }
    }

    func activate(owner: AnyObject, _ bindings: [Binding]) {
        deactivateAll()
        self.owner = owner
        for b in bindings {
            if let t = HotkeyCenter.shared.register(Shortcut(key: b.key, modifiers: b.modifiers), handler: b.action) {
                tokens.append(t)
            }
        }
    }

    func deactivate(owner: AnyObject) {
        guard self.owner === owner else { return }
        deactivateAll()
    }

    private func deactivateAll() {
        tokens.forEach { HotkeyCenter.shared.unregister($0) }
        tokens.removeAll()
        owner = nil
    }
}

// MARK: - Hover tracking

/// Adds one `.inVisibleRect` tracking area (it follows resizes by itself) without touching AppKit's own areas
/// (tool tips, cursor rects).
@MainActor
func installHoverTracking(on view: NSView, existing: inout NSTrackingArea?) {
    guard existing == nil else { return }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: view, userInfo: nil)
    view.addTrackingArea(area)
    existing = area
}

// MARK: - Buttons

/// Overlay control: an SF Symbol circle (card / pin corners) or a capsule pill (Copy / Save / Trash). Works on
/// first click in an inactive app and highlights on hover.
///
/// Backdrops: `.light` (pins) is a white layer fill with a soft shadow. `.vibrant` (Quick Access cards; CleanShot
/// `PopupBasic`, binary) is an `NSVisualEffectView` — `.sidebar` material, `.withinWindow`, `.active`, `.aqua` —
/// pinned to the button's edges and fully rounded, with `labelColor` content under the `.aqua` appearance.
///
/// The glyph and title are drawn by our own centred subviews, never by the button cell: a cell with an image
/// reports non-zero `alignmentRectInsets` (≈2 pt top, 1.5 pt bottom on macOS 26), so Auto Layout sized the
/// alignment rect to the constraints and grew the *frame* — and the layer-drawn circle — into a tall oval.
final class OverlayButton: NSButton {
    enum Style { case icon(String), pill(String), symbolPill(String) }
    enum Backdrop { case light, vibrant }
    /// Pills (binary): 27 pt tall, 12 pt medium title, 9 pt title padding on each side.
    static let pillHeight: CGFloat = 27
    static let pillPadding: CGFloat = 9
    static let pillFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// Content colour on the `.light` backdrop.
    static let lightGlyphColor = NSColor(white: 0.13, alpha: 1)

    private var style: Style
    private let backdrop: Backdrop
    private let vibrancy = PassthroughEffectView()
    private let highlight = PassthroughView()
    private let glyph = PassthroughImageView()
    private let label = PassthroughLabel(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    /// Required lower bound and low-priority preferred width (a sibling's equal-width constraint may widen a pill).
    private var minWidthConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private var hoverArea: NSTrackingArea?
    private var hovering = false { didSet { updateFill(animated: true) } }
    private var pressed = false { didSet { updateFill(animated: false) } }
    var onClick: (() -> Void)?
    /// Diameter of an `.icon` circle.
    var side: CGFloat { didSet { if side != oldValue { apply(style, tooltip: toolTip) } } }

    init(_ style: Style, backdrop: Backdrop = .light, side: CGFloat = 22, tooltip: String? = nil, action: (() -> Void)? = nil) {
        self.style = style
        self.backdrop = backdrop
        self.side = side
        self.onClick = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        title = ""
        imagePosition = .noImage
        focusRingType = .none
        wantsLayer = true
        target = self
        self.action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        var layered: [NSView] = []
        switch backdrop {
        case .light:
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 2
            layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        case .vibrant:
            appearance = NSAppearance(named: .aqua)
            layer?.cornerCurve = .circular
            layer?.masksToBounds = true          // rounds the vibrancy view
            vibrancy.material = .sidebar
            vibrancy.blendingMode = .withinWindow
            vibrancy.state = .active
            vibrancy.appearance = NSAppearance(named: .aqua)
            highlight.wantsLayer = true
            layered = [vibrancy, highlight]
        }
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = backdrop == .vibrant ? .labelColor : Self.lightGlyphColor
        label.font = Self.pillFont
        label.textColor = backdrop == .vibrant ? .labelColor : Self.lightGlyphColor
        label.alignment = .center
        for v in layered + [glyph, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        minWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.priority = .defaultLow
        var constraints: [NSLayoutConstraint] = [
            heightConstraint, minWidthConstraint, widthConstraint,
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        for v in layered {
            constraints += [
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        apply(style, tooltip: tooltip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The frame is exactly the drawn circle / capsule.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    /// Swaps glyph/title in place (lock ↔ unlock, Save ↔ Trash) and sizes the button for it.
    func apply(_ style: Style, tooltip: String?) {
        self.style = style
        toolTip = tooltip
        let size: CGSize
        switch style {
        case .icon(let symbol):
            // Vibrant (card) glyphs scale with the circle (binary: ≈ 0.45 × side); pin glyphs stay 11 pt.
            glyph.image = Self.symbol(symbol, pointSize: backdrop == .vibrant ? (side * 0.45).rounded() : 11, tooltip)
            label.stringValue = ""
            setAccessibilityLabel(tooltip)
            size = CGSize(width: side, height: side)
        case .symbolPill(let symbol):
            glyph.image = Self.symbol(symbol, pointSize: 12, tooltip)
            label.stringValue = ""
            setAccessibilityLabel(tooltip)
            size = CGSize(width: (glyph.image?.size.width ?? 0).rounded(.up) + 2 * Self.pillPadding, height: Self.pillHeight)
        case .pill(let title):
            glyph.image = nil
            label.stringValue = title
            setAccessibilityLabel(title)
            let titleWidth = (title as NSString).size(withAttributes: [.font: Self.pillFont]).width.rounded(.up)
            size = CGSize(width: titleWidth + 2 * Self.pillPadding, height: Self.pillHeight)
        }
        heightConstraint.constant = size.height
        minWidthConstraint.constant = size.width
        widthConstraint.constant = size.width
        layer?.cornerRadius = size.height / 2
        updateFill(animated: false)
    }

    private static func symbol(_ name: String, pointSize: CGFloat, _ description: String?) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTracking(on: self, existing: &hoverArea)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)   // runs the tracking loop; returns on mouse-up
        pressed = false
    }

    override func layout() {
        super.layout()
        guard backdrop == .light else { return }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
    }

    @objc private func clicked() { onClick?() }

    private func updateFill(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.12 : 0)
        CATransaction.setDisableActions(!animated)
        switch backdrop {
        case .light:
            let alpha: CGFloat = pressed ? 0.7 : hovering ? 0.98 : 0.85
            layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        case .vibrant:
            let tint: NSColor = pressed ? .black.withAlphaComponent(0.12) : hovering ? .white.withAlphaComponent(0.3) : .clear
            highlight.layer?.backgroundColor = tint.cgColor
        }
        CATransaction.commit()
    }
}

// MARK: - Circular progress

final class CircularProgressView: NSView {
    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()
    var progress: Double = 0 { didSet { bar.strokeEnd = CGFloat(min(max(progress, 0), 1)) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, bar] {
            l.fillColor = nil
            l.lineWidth = 4
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        bar.strokeColor = NSColor.white.cgColor
        bar.strokeEnd = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let r = bounds.insetBy(dx: 3, dy: 3)
        // Start at 12 o'clock, go clockwise.
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, bar] { l.frame = bounds; l.path = path }
    }
}

// MARK: - Thumbnails

@MainActor
public enum Thumbnailer {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    private static func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(mtime)|\(Int(maxPixel))" as NSString
    }

    /// Asynchronously produces a thumbnail whose longest side is ≤ `maxPixel` pixels. Calls back on the main thread.
    static func thumbnail(for url: URL, kind: MediaKind, maxPixel: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let k = key(url, maxPixel)
        if let hit = cache.object(forKey: k) { completion(hit); return }
        let finish: (CGImage?) -> Void = { cg in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                        ?? NSWorkspace.shared.icon(forFile: url.path)
                    if cg != nil { cache.setObject(img, forKey: k) }
                    completion(img)
                }
            }
        }
        if kind == .image || kind == .gif {
            DispatchQueue.global(qos: .userInitiated).async {
                finish(downsample(url, maxPixel: maxPixel))
            }
        } else {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixel, height: maxPixel),
                                                   scale: 1, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                finish(rep?.cgImage)
            }
        }
    }

    /// Decodes the file straight to a `maxPixel`-bounded bitmap (pins and cards never hold the full image).
    public nonisolated static func downsample(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, Int(maxPixel)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Formatting

enum OverlayFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Key codes used by overlays

enum Keys {
    static let c = kVK_ANSI_C, s = kVK_ANSI_S, e = kVK_ANSI_E, p = kVK_ANSI_P, u = kVK_ANSI_U, w = kVK_ANSI_W
    static let space = kVK_Space, escape = kVK_Escape, returnKey = kVK_Return, keypadEnter = kVK_ANSI_KeypadEnter
    static let delete = kVK_Delete
    static let left = kVK_LeftArrow, right = kVK_RightArrow, up = kVK_UpArrow, down = kVK_DownArrow
}

// MARK: - Menus & passthrough views

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         symbol: String? = nil, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        self.state = state
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

/// Non-interactive label whose clicks reach the control underneath.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Image view that never intercepts mouse events (its container handles clicks and drags).
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Blur/tint layer that never intercepts mouse events.
final class PassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Aspect-fill thumbnail (binary: the card has a fixed 1.4 aspect and the thumbnail fills it, cropped — never
/// letterboxed). Static images are drawn as layer contents; animated GIFs use an `NSImageView` (so they keep
/// playing) sized to the fill rect and clipped; videos can attach a looping player layer.
final class ThumbnailView: NSView {
    private var staticImage: NSImage?
    private let animatedView = NSImageView()
    private var playerLayer: AVPlayerLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        animatedView.imageScaling = .scaleAxesIndependently   // its frame already has the image's aspect
        animatedView.animates = true
        animatedView.isHidden = true
        addSubview(animatedView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }

    var image: NSImage? { staticImage ?? animatedView.image }

    func setImage(_ image: NSImage?, animated: Bool) {
        if animated {
            staticImage = nil
            animatedView.image = image
            animatedView.isHidden = false
            needsLayout = true
        } else {
            staticImage = image
            animatedView.image = nil
            animatedView.isHidden = true
        }
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.contentsGravity = .resizeAspectFill
        layer.minificationFilter = .trilinear   // crisp downscale of the oversampled thumbnail
        layer.masksToBounds = true
        guard let img = staticImage else { layer.contents = nil; return }
        let scale = img.recommendedLayerContentsScale(window?.backingScaleFactor ?? 2)
        layer.contents = img.layerContents(forContentsScale: scale)
        layer.contentsScale = scale
    }

    /// Shows `player` on top of the poster frame (nil removes it).
    func attach(_ player: AVPlayer?) {
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        guard let player, let layer else { return }
        let pl = AVPlayerLayer(player: player)
        pl.videoGravity = .resizeAspectFill
        pl.frame = bounds
        layer.addSublayer(pl)
        playerLayer = pl
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
        // Aspect-fill: the GIF view covers the bounds at the image's aspect; the overflow is clipped.
        let size = animatedView.image?.size ?? .zero
        guard size.width > 0, size.height > 0 else { animatedView.frame = bounds; return }
        let fill = max(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * fill, h = size.height * fill
        animatedView.frame = CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}

/// Plain view that never intercepts mouse events.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let real controls inside (buttons) receive clicks; everything else falls through to the container.
        // Faded-out chrome (alpha 0) is not clickable: hit-testing ignores alpha by default.
        guard alphaValue > 0.01 else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

extension NSImage {
    /// Stretchable rounded-rect mask for `NSVisualEffectView.maskImage` (behind-window blur ignores layer corner radii).
    static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}
