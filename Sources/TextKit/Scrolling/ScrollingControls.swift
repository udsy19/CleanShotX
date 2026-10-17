import AppKit
import SuperScreenshotCore

/// The scrolling-capture controls (SGControlsView + auto-scroll child windows): small pills docked at the
/// bottom-centre inside the selection — "▶ Auto-Scroll" above, "?" · "✕ Cancel" · "Start" / "✓ Done" below —
/// plus a horizontal "Auto-Scroll" pill at the right edge once horizontal scrolling is detected.
@MainActor final class ScrollingControls: NSObject {
    private let panel = OverlayPanel(clickThrough: false)
    private let horizontalPanel = OverlayPanel(clickThrough: false)

    var onStart: () -> Void = {}
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAutoScroll: (_ axis: ScrollAxis, _ on: Bool) -> Void = { _, _ in }

    private lazy var autoScrollButton = PillButton("Auto-Scroll", symbol: "play.fill", style: .dark,
                                                   target: self, action: #selector(verticalAutoScrollClicked))
    private lazy var horizontalAutoScrollButton = PillButton("Auto-Scroll", symbol: "play.fill", style: .dark,
                                                             target: self, action: #selector(horizontalAutoScrollClicked))
    private lazy var helpButton = PillButton("", symbol: "questionmark", style: .dark, target: self, action: #selector(helpClicked))
    private lazy var cancelButton = PillButton("Cancel", symbol: "xmark", style: .dark, target: self, action: #selector(cancelClicked))
    private lazy var startButton = PillButton("Start Capture", symbol: "play.fill", style: .light,
                                              target: self, action: #selector(startClicked))
    private lazy var doneButton = PillButton("Done", symbol: "checkmark", style: .light, target: self, action: #selector(doneClicked))
    private var popover: NSPopover?
    private var autoScrollOn = false
    private var detectedAxis: ScrollAxis?

    private var area: CGRect = .zero
    private var screen: NSScreen?

    override init() {
        super.init()
        helpButton.toolTip = "Scrolling capture tips"
        autoScrollButton.toolTip = "Scroll the content automatically (needs Accessibility permission)"
        horizontalAutoScrollButton.toolTip = autoScrollButton.toolTip
        doneButton.isHidden = true

        let row = NSStackView(views: [helpButton, cancelButton, startButton, doneButton])
        row.spacing = 6
        let column = NSStackView(views: [autoScrollButton, row])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        panel.contentView = column
        panel.acceptsKey = true

        horizontalPanel.contentView = horizontalAutoScrollButton
    }

    /// Screen frames covered by the controls (auto-scroll must not point at them).
    var coveredFrames: [CGRect] { [panel, horizontalPanel].filter(\.isVisible).map(\.frame) }

    /// Switches from "Start Capture" to "Done".
    func setCapturing() {
        startButton.isHidden = true
        doneButton.isHidden = false
        layout()
    }

    /// Shows the auto-scroll pill matching the detected direction.
    func setDetectedAxis(_ axis: ScrollAxis) {
        detectedAxis = axis
        autoScrollButton.isHidden = axis == .horizontal
        layout()
    }

    func setAutoScroll(_ on: Bool) {
        autoScrollOn = on
        for b in [autoScrollButton, horizontalAutoScrollButton] {
            b.set(title: on ? "Stop Auto-Scroll" : "Auto-Scroll", symbol: on ? "stop.fill" : "play.fill")
        }
        layout()
    }

    // MARK: Placement

    func place(in area: CGRect, on screen: NSScreen) {
        self.area = area; self.screen = screen
        layout()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func layout() {
        guard let screen else { return }
        let vis = screen.frame, inset: CGFloat = 10

        let size = panel.contentView?.fittingSize ?? .zero
        let x = min(max(area.midX - size.width / 2, vis.minX + inset), vis.maxX - inset - size.width)
        let fitsInside = area.height >= size.height + 100 && area.width >= size.width + 2 * inset
        var y = area.minY + inset
        if !fitsInside {
            y = area.minY - inset - size.height                                // below the area
            if y < screen.visibleFrame.minY + inset { y = area.maxY + inset }  // above it
            if y + size.height > screen.visibleFrame.maxY - inset { y = area.minY + inset }
        }
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)

        guard detectedAxis == .horizontal else { horizontalPanel.orderOut(nil); return }
        let hs = horizontalAutoScrollButton.intrinsicContentSize
        var hx = area.maxX - inset - hs.width
        if area.width < hs.width + 120 { hx = min(area.maxX + inset, vis.maxX - inset - hs.width) }
        let hy = area.midY - hs.height / 2
        horizontalPanel.setFrame(NSRect(x: hx.rounded(), y: hy.rounded(), width: hs.width, height: hs.height), display: true)
        horizontalPanel.orderFrontRegardless()
    }

    // MARK: Actions

    @objc private func verticalAutoScrollClicked() { onAutoScroll(.vertical, !autoScrollOn) }
    @objc private func horizontalAutoScrollClicked() { onAutoScroll(.horizontal, !autoScrollOn) }
    @objc private func startClicked() { onStart() }
    @objc private func doneClicked() { onDone() }
    @objc private func cancelClicked() { onCancel() }

    @objc private func helpClicked() {
        if let popover, popover.isShown { popover.close(); return }
        let title = NSTextField(labelWithString: "Scrolling capture may fail when:")
        title.font = .boldSystemFont(ofSize: 13)
        let tips = [
            "The area includes animations or videos.",
            "The content doesn't scroll straight down or straight right.",
            "You scroll too fast — scroll slowly and steadily.",
            "You scroll back up — capture pauses until you return.",
            "The area includes more than the scrolling content (sidebars, scroll bars).",
        ]
        let rows: [NSView] = [title] + tips.map { tip in
            let l = NSTextField(wrappingLabelWithString: "•  " + tip)
            l.font = .systemFont(ofSize: 12)
            l.preferredMaxLayoutWidth = 300
            return l
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let vc = NSViewController()
        vc.view = stack
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: helpButton.bounds, of: helpButton, preferredEdge: .maxY)
        popover = p
    }

    func close() {
        popover?.close()
        popover = nil
        panel.orderOut(nil)
        horizontalPanel.orderOut(nil)
    }
}
