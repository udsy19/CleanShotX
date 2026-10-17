import AppKit
import ShotcraftCore

/// Orientation choice in the control bar; persisted per user.
enum ScrollOrientationChoice: String, Codable, CaseIterable {
    case auto, vertical, horizontal
    var axis: ScrollAxis? {
        switch self {
        case .auto: nil
        case .vertical: .vertical
        case .horizontal: .horizontal
        }
    }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .vertical: "Vertical"
        case .horizontal: "Horizontal"
        }
    }
    var symbol: String {
        switch self {
        case .auto: "arrow.up.and.down.and.arrow.left.and.right"
        case .vertical: "arrow.up.and.down"
        case .horizontal: "arrow.left.and.right"
        }
    }
}

extension Defaults.Keys {
    static let textkitScrollingOrientation = Key<ScrollOrientationChoice>("textkit.scrollingOrientation", default: .auto)
}

/// The scrolling-capture control bar (SGControlsView): orientation, Auto-Scroll, Start/Done, counter, help, Cancel.
@MainActor final class ScrollingControls: NSObject {
    let panel = ScrollingPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), clickThrough: false)

    var onStart: () -> Void = {}
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAutoScroll: (Bool) -> Void = { _ in }
    var onOrientation: (ScrollOrientationChoice) -> Void = { _ in }

    private let orientationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoScrollButton = NSButton()
    private let startButton = NSButton(title: "Start Capture", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let counter = NSTextField(labelWithString: "")
    private let helpButton = NSButton()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var popover: NSPopover?

    override init() {
        super.init()
        for choice in ScrollOrientationChoice.allCases {
            orientationPopup.addItem(withTitle: choice.title)
            orientationPopup.lastItem?.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: choice.title)
            orientationPopup.lastItem?.representedObject = choice.rawValue
        }
        orientationPopup.selectItem(at: ScrollOrientationChoice.allCases.firstIndex(of: Defaults[.textkitScrollingOrientation]) ?? 0)
        orientationPopup.target = self
        orientationPopup.action = #selector(orientationChanged)
        orientationPopup.toolTip = "Scroll direction"

        autoScrollButton.setButtonType(.pushOnPushOff)
        autoScrollButton.bezelStyle = .rounded
        autoScrollButton.title = "Auto-Scroll"
        autoScrollButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        autoScrollButton.imagePosition = .imageLeading
        autoScrollButton.target = self
        autoScrollButton.action = #selector(autoScrollClicked)
        autoScrollButton.toolTip = "Scroll the content automatically (requires Accessibility permission)"

        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startClicked)

        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        doneButton.isHidden = true

        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        counter.textColor = .secondaryLabelColor
        counter.isHidden = true

        helpButton.bezelStyle = .helpButton
        helpButton.title = ""
        helpButton.target = self
        helpButton.action = #selector(helpClicked)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        let stack = NSStackView(views: [orientationPopup, autoScrollButton, counter, helpButton, cancelButton, startButton, doneButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let fx = makeHUDBackground(cornerRadius: 10)
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel.contentView = fx
        panel.acceptsKey = true
    }

    var orientation: ScrollOrientationChoice {
        (orientationPopup.selectedItem?.representedObject as? String).flatMap(ScrollOrientationChoice.init) ?? .auto
    }

    /// Switches the bar to its capturing state.
    func setCapturing() {
        startButton.isHidden = true
        doneButton.isHidden = false
        counter.isHidden = false
        layoutPanel()
    }

    func setDetectedAxis(_ axis: ScrollAxis) {
        orientationPopup.isEnabled = false
        if let i = ScrollOrientationChoice.allCases.firstIndex(where: { $0.axis == axis }) { orientationPopup.selectItem(at: i) }
        autoScrollButton.image = NSImage(systemSymbolName: axis == .vertical ? "arrow.down.circle" : "arrow.right.circle",
                                         accessibilityDescription: nil)
    }

    func setAutoScroll(_ on: Bool) { autoScrollButton.state = on ? .on : .off }

    func setCounter(frames: Int) { counter.stringValue = frames == 1 ? "1 frame" : "\(frames) frames" }

    // MARK: Placement

    private var area: CGRect = .zero
    private var screen: NSScreen?

    /// Below the area, else above it, else inside its bottom edge.
    func place(below area: CGRect, on screen: NSScreen) {
        self.area = area; self.screen = screen
        layoutPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func layoutPanel() {
        guard let screen else { return }
        let size = panel.contentView?.fittingSize ?? .zero
        let vis = screen.visibleFrame, gap: CGFloat = 12
        let x = min(max(area.midX - size.width / 2, vis.minX + gap), vis.maxX - gap - size.width)
        var y = area.minY - gap - size.height
        if y < vis.minY + gap { y = area.maxY + gap }
        if y + size.height > vis.maxY - gap { y = area.minY + gap }
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    // MARK: Actions

    @objc private func orientationChanged() {
        Defaults[.textkitScrollingOrientation] = orientation
        onOrientation(orientation)
    }
    @objc private func autoScrollClicked() { onAutoScroll(autoScrollButton.state == .on) }
    @objc private func startClicked() { onStart() }
    @objc private func doneClicked() { onDone() }
    @objc private func cancelClicked() { onCancel() }

    @objc private func helpClicked() {
        if let popover, popover.isShown { popover.close(); return }
        let title = NSTextField(labelWithString: "Tips for a clean scrolling capture")
        title.font = .boldSystemFont(ofSize: 13)
        let tips = [
            "Select only the part that scrolls — leave out scroll bars and fixed sidebars.",
            "Scroll slowly and in one direction (down or right).",
            "Avoid areas with animations or playing videos.",
            "Scrolling back up pauses the capture until you return.",
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
        panel.orderOut(nil)
    }
}
