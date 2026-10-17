import AppKit
import SuperScreenshotCore

/// Editor window: Space plays/pauses, I / O set the trim start / end at the playhead (unless a text
/// field is being edited).
final class EditorWindow: NSWindow {
    var onSpace: (() -> Void)?
    var onMarkIn: (() -> Void)?
    var onMarkOut: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard !(firstResponder is NSTextView), event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (49, _): onSpace?()
        case (_, "i"): onMarkIn?()
        case (_, "o"): onMarkOut?()
        default: super.keyDown(with: event)
        }
    }
}

/// Shared window chrome for the video and GIF editors: a transport row (play, time) above the
/// trim timeline, and title-bar buttons.
@MainActor
enum EditorChrome {
    static func makeWindow(title: String, url: URL, size: NSSize, minSize: NSSize) -> EditorWindow {
        let window = EditorWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = title
        window.representedURL = url
        return window
    }

    /// Buttons on the trailing side of the title bar (the last one is the default, blue).
    static func addTitlebarButtons(_ buttons: [NSButton], to window: NSWindow) {
        let stack = NSStackView(views: buttons)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        let size = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: size.width, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }

    static func button(_ title: String, symbolName: String?, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .push
        b.controlSize = .regular
        if let symbolName { b.image = symbol(symbolName, size: 12); b.imagePosition = .imageLeading }
        return b
    }

    static func playButton(target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.target = target
        b.action = action
        b.toolTip = "Play / Pause (Space)"
        b.setAccessibilityLabel("Play")
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    static func timeLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "0:00 / 0:00")
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// "0:07.4"
    static func format(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return RecordingMath.formatElapsed(s) + String(format: ".%d", Int((s - s.rounded(.down)) * 10))
    }

    /// Bottom area: transport row above the timeline, on a bar-coloured background.
    static func bottomBar(transport: [NSView], timeline: TimelineView) -> NSView {
        let fx = NSVisualEffectView()
        fx.material = .titlebar
        fx.blendingMode = .withinWindow
        fx.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: transport)
        row.spacing = 10
        let column = NSStackView(views: [row, timeline])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 14, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(column)
        timeline.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: fx.leadingAnchor), column.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            column.topAnchor.constraint(equalTo: fx.topAnchor), column.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            timeline.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            timeline.heightAnchor.constraint(equalToConstant: TimelineView.height),
        ])
        return fx
    }
}

/// Thumbnail strip with yellow trim handles and a playhead. Drag a handle to trim, click or drag
/// anywhere else to scrub.
final class TimelineView: NSView {
    static let height: CGFloat = 56

    var duration: Double = 0 { didSet { end = duration; start = 0; needsDisplay = true } }
    private(set) var start: Double = 0
    private(set) var end: Double = 0
    var playhead: Double = 0 { didSet { if playhead != oldValue { needsDisplay = true } } }
    var thumbnails: [CGImage] = [] { didSet { needsDisplay = true } }
    var isEnabled = true

    /// Called continuously while trimming.
    var onTrimChange: ((_ start: Double, _ end: Double) -> Void)?
    /// Called continuously while scrubbing.
    var onScrub: ((Double) -> Void)?

    private let handleWidth: CGFloat = 12
    private let minimumDuration = 0.1
    private enum Drag { case none, start, end, scrub }
    private var drag: Drag = .none

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Timeline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setTrim(start s: Double, end e: Double) {
        let s2 = max(0, min(s, duration)), e2 = max(0, min(e, duration))
        guard e2 - s2 >= min(minimumDuration, duration) else { return }
        start = s2; end = e2
        needsDisplay = true
        onTrimChange?(start, end)
    }

    var isTrimmed: Bool { start > 0.005 || end < duration - 0.005 }

    /// Track rect between the handles' outer edges.
    private var track: CGRect { bounds.insetBy(dx: handleWidth, dy: 2) }

    private func x(for t: Double) -> CGFloat {
        guard duration > 0 else { return track.minX }
        return track.minX + track.width * CGFloat(t / duration)
    }

    private func time(at x: CGFloat) -> Double {
        guard track.width > 0 else { return 0 }
        return max(0, min(duration, Double((x - track.minX) / track.width) * duration))
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = track
        let clip = NSBezierPath(roundedRect: t, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.6).setFill()
        clip.fill()
        if !thumbnails.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            clip.addClip()
            let first = thumbnails[0]
            let thumbW = max(8, t.height * CGFloat(first.width) / CGFloat(max(1, first.height)))
            var x = t.minX
            while x < t.maxX {
                // Pick the thumbnail nearest this position in time.
                let idx = min(thumbnails.count - 1, Int(CGFloat(thumbnails.count) * (x - t.minX) / max(1, t.width)))
                let image = thumbnails[idx]
                ctx.saveGState()
                ctx.translateBy(x: x, y: t.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbW, height: t.height))
                ctx.restoreGState()
                x += thumbW
            }
            ctx.restoreGState()
        }
        // Dim outside the trim range.
        let sx = x(for: start), ex = x(for: end)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(rect: CGRect(x: t.minX, y: t.minY, width: max(0, sx - t.minX), height: t.height)).fill()
        NSBezierPath(rect: CGRect(x: ex, y: t.minY, width: max(0, t.maxX - ex), height: t.height)).fill()

        // Trim frame with handles.
        let frame = CGRect(x: sx - handleWidth, y: 0, width: ex - sx + handleWidth * 2, height: bounds.height)
        let yellow = isEnabled ? NSColor.systemYellow : NSColor.tertiaryLabelColor
        yellow.setFill()
        let outer = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        outer.append(NSBezierPath(rect: CGRect(x: sx, y: 3, width: max(0, ex - sx), height: bounds.height - 6)).reversed)
        outer.fill()
        NSColor.black.withAlphaComponent(0.55).setFill()
        for hx in [sx - handleWidth / 2, ex + handleWidth / 2] {
            NSBezierPath(roundedRect: CGRect(x: hx - 1.5, y: bounds.midY - 8, width: 3, height: 16), xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Playhead.
        let px = x(for: playhead)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: px - 1.5, y: 0, width: 3, height: bounds.height), xRadius: 1.5, yRadius: 1.5).fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let edge = NSBezierPath(roundedRect: CGRect(x: px - 1.5, y: 0, width: 3, height: bounds.height), xRadius: 1.5, yRadius: 1.5)
        edge.lineWidth = 0.5
        edge.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: x(for: start) - handleWidth, y: 0, width: handleWidth, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: x(for: end), y: 0, width: handleWidth, height: bounds.height), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let sx = x(for: start), ex = x(for: end)
        if p.x >= sx - handleWidth - 2 && p.x <= sx + 2 { drag = .start }
        else if p.x >= ex - 2 && p.x <= ex + handleWidth + 2 { drag = .end }
        else { drag = .scrub; scrub(to: p.x) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none: break
        case .scrub: scrub(to: p.x)
        case .start:
            let t = min(time(at: p.x + handleWidth / 2), end - minimumDuration)
            setTrim(start: t, end: end)
            playhead = start
            onScrub?(start)
        case .end:
            let t = max(time(at: p.x - handleWidth / 2), start + minimumDuration)
            setTrim(start: start, end: t)
            playhead = end
            onScrub?(end)
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
        window?.invalidateCursorRects(for: self)
    }

    private func scrub(to x: CGFloat) {
        playhead = min(max(time(at: x), start), end)
        onScrub?(playhead)
    }

    override func accessibilityValue() -> Any? { "\(EditorChrome.format(start)) to \(EditorChrome.format(end))" }
}
