import AppKit
import QuartzCore
import SuperScreenshotCore

extension NSWindow.Level {
    /// Above regular app windows (the area being scrolled) but below system UI.
    static let textKitOverlay = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
}

/// Borderless transparent panel that may become key (for Return/Esc) without activating the app.
final class OverlayPanel: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    init(clickThrough: Bool, shadow: Bool = false) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        level = .textKitOverlay
        ignoresMouseEvents = clickThrough
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// The two pill looks used by CleanShot's overlays: near-black HUD pills and light "instruction" pills.
enum PillStyle {
    case dark, light

    var fill: NSColor {
        switch self {
        case .dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 0.9)   // #1C1C1E @ 90 %
        case .light: NSColor.white.withAlphaComponent(0.8)
        }
    }
    var pressedFill: NSColor {
        switch self {
        case .dark: NSColor(srgbRed: 0.24, green: 0.24, blue: 0.25, alpha: 0.95)
        case .light: NSColor(white: 0.84, alpha: 0.95)
        }
    }
    var foreground: NSColor {
        switch self {
        case .dark: .white
        case .light: NSColor(white: 0.1, alpha: 1)
        }
    }
    var stroke: NSColor {
        switch self {
        case .dark: NSColor.white.withAlphaComponent(0.14)
        case .light: NSColor.black.withAlphaComponent(0.08)
        }
    }
}

/// Rounded pill with an SF Symbol and a one-line label (toasts and scrolling-capture alerts).
/// `cornerRadius` nil = fully rounded.
final class PillLabelView: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private let style: PillStyle
    private let fixedRadius: CGFloat?

    init(style: PillStyle, fontSize: CGFloat, cornerRadius: CGFloat? = nil,
         insets: NSEdgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)) {
        self.style = style
        fixedRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = style.stroke.cgColor
        if style == .light {
            // Frosted white: blur below a translucent white fill.
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: .aqua)
            blur.autoresizingMask = [.width, .height]
            addSubview(blur)
        }
        let tint = NSView(frame: bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = style.fill.cgColor
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)

        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = style.foreground
        label.lineBreakMode = .byTruncatingTail
        icon.symbolConfiguration = .init(pointSize: fontSize, weight: .semibold)
        icon.contentTintColor = style.foreground
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ text: String, symbol: String, tint: NSColor? = nil) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint ?? style.foreground
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = fixedRadius ?? bounds.height / 2
    }
}

/// Small capsule button (CleanShot's "✕ Cancel" / "✓ Done" / "▶ Auto-Scroll" pills): 24 pt high, 12 pt medium.
final class PillButton: NSButton {
    static let height: CGFloat = 24
    private let style: PillStyle

    init(_ title: String, symbol: String?, style: PillStyle, target: AnyObject?, action: Selector) {
        self.style = style
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.borderWidth = 1
        layer?.borderColor = style.stroke.cgColor
        layer?.backgroundColor = style.fill.cgColor
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true
        focusRingType = .none
        set(title: title, symbol: symbol)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(title: String, symbol: String?) {
        attributedTitle = NSAttributedString(string: title.isEmpty ? "" : title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: style.foreground,
        ])
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title.isEmpty ? toolTip : nil) }?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        contentTintColor = style.foreground
        setAccessibilityLabel(title.isEmpty ? toolTip : title)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let inner = super.intrinsicContentSize
        guard !attributedTitle.string.isEmpty else { return NSSize(width: Self.height, height: Self.height) }
        return NSSize(width: ceil(inner.width) + 20, height: Self.height)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = (flag ? style.pressedFill : style.fill).cgColor
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Bottom-centre dark toast ("Text has been copied" / "No text detected"); fades out after `duration`.
@MainActor enum Toast {
    private static var panel: OverlayPanel?
    private static var hideWork: DispatchWorkItem?
    private static var generation = 0

    static func show(_ text: String, symbol: String, on screen: NSScreen = .active, duration: TimeInterval = 1.5) {
        hideWork?.cancel()
        generation += 1
        let shown = generation
        let p = panel ?? OverlayPanel(clickThrough: true, shadow: true)
        p.level = .statusBar
        panel = p
        let content = PillLabelView(style: .dark, fontSize: 13, cornerRadius: 10,
                                    insets: NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 16))
        content.set(text, symbol: symbol)
        p.contentView = content
        let size = content.fittingSize
        let vis = screen.visibleFrame
        p.setFrame(NSRect(x: (vis.midX - size.width / 2).rounded(), y: (vis.minY + 72).rounded(),
                          width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { if generation == shown { p.orderOut(nil) } }   // not replaced meanwhile
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
