import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import ShotcraftCore

// Shared building blocks for Quick Access cards, pins and the history window.

// MARK: - Window levels / behaviour

enum OverlayWindow {
    /// Pins float above normal windows; Quick Access cards float above pins.
    static let pinLevel = NSWindow.Level.floating
    static let quickAccessLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
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
        p.becomesKeyOnlyIfNeeded = true
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

// MARK: - Temporary hotkeys while an overlay is hovered

/// Keyboard shortcuts for a hovered overlay are registered as global hotkeys only while the pointer is over it,
/// so they work without activating Shotcraft (the frontmost app keeps focus).
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

// MARK: - Buttons

/// Rounded overlay button: either an SF Symbol in a circle or a text pill. Works on first click in an
/// inactive app and highlights on hover.
final class OverlayButton: NSButton {
    enum Style { case icon(String), pill(String) }
    private let style: Style
    private var hovering = false { didSet { updateColors() } }
    var onClick: (() -> Void)?

    init(_ style: Style, tooltip: String? = nil, diameter: CGFloat = 26, action: (() -> Void)? = nil) {
        self.style = style
        self.onClick = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        toolTip = tooltip
        target = self
        self.action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        switch style {
        case .icon(let symbol):
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(.init(pointSize: diameter * 0.46, weight: .semibold))
            imagePosition = .imageOnly
            layer?.cornerRadius = diameter / 2
            NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter),
                                         heightAnchor.constraint(equalToConstant: diameter)])
        case .pill(let title):
            self.title = title
            font = .systemFont(ofSize: 13, weight: .semibold)
            layer?.cornerRadius = 13
            NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 26),
                                         widthAnchor.constraint(greaterThanOrEqualToConstant: 76)])
        }
        setAccessibilityLabel(tooltip ?? title)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    @objc private func clicked() { onClick?() }

    private func updateColors() {
        switch style {
        case .icon:
            layer?.backgroundColor = NSColor.black.withAlphaComponent(hovering ? 0.75 : 0.55).cgColor
            contentTintColor = .white
        case .pill(let t):
            layer?.backgroundColor = NSColor.white.withAlphaComponent(hovering ? 1 : 0.88).cgColor
            attributedTitle = NSAttributedString(string: t, attributes: [
                .foregroundColor: NSColor.black.withAlphaComponent(0.85),
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            ])
        }
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        if case .pill = style { s.width += 24 }
        return s
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
enum Thumbnailer {
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

    nonisolated static func downsample(_ url: URL, maxPixel: CGFloat) -> CGImage? {
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

    static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }
}

// MARK: - Key codes used by overlays

enum Keys {
    static let c = kVK_ANSI_C, s = kVK_ANSI_S, a = kVK_ANSI_A, p = kVK_ANSI_P, u = kVK_ANSI_U, w = kVK_ANSI_W
    static let space = kVK_Space, escape = kVK_Escape
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

/// Image view that never intercepts mouse events (its container handles clicks and drags).
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Plain view that never intercepts mouse events.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let real controls inside (buttons) receive clicks; everything else falls through to the container.
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
