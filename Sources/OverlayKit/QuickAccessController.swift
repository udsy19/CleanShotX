import AppKit
import Combine
import ShotcraftCore

/// Owns the Quick Access Overlay stack (CleanShot's `PopupController`).
@MainActor
final class QuickAccessController: QuickAccessServicing {
    static let shared = QuickAccessController()

    /// Newest first (index 0 sits at the bottom of the stack).
    private(set) var cards: [QuickAccessCard] = []
    /// Media of closed cards, most recent last (for "Restore Last Capture").
    private var recentlyClosed: [CapturedMedia] = []
    private let maxRecentlyClosed = 30

    private var header: OverlayPanel?
    private var screen: NSScreen?
    /// "Temporarily hide": the stack slid down so only the newest card's top edge peeks out; hovering it restores.
    private(set) var isSlidDown = false
    private var displayTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var defaultsSub: AnyCancellable?

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: CapturedMedia.didChange, object: nil, queue: .main) { [weak self] n in
            guard let media = n.object as? CapturedMedia else { return }
            MainActor.assumeIsolated { self?.mediaDidChange(media) }
        })
        // UploadKit reports progress for every upload, wherever it was started.
        observers.append(NotificationCenter.default.addObserver(forName: CapturedMedia.uploadProgress, object: nil, queue: .main) { [weak self] n in
            guard let media = n.object as? CapturedMedia, let fraction = n.userInfo?["fraction"] as? Double else { return }
            MainActor.assumeIsolated { self?.cards.first { $0.media.id == media.id }?.uploadProgressed(fraction) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screen = nil; self?.layout(animated: false) }
        })
        let relayoutKeys: Set<String> = [Defaults.Keys.quickAccessSide.name, Defaults.Keys.quickAccessSize.name,
                                         Defaults.Keys.quickAccessScreen.name]
        let cardKeys: Set<String> = [Defaults.Keys.quickAccessShowUploadButton.name, Defaults.Keys.quickAccessAutoClose.name,
                                     Defaults.Keys.quickAccessAutoCloseSeconds.name]
        defaultsSub = Defaults.changes.receive(on: DispatchQueue.main).sink { [weak self] name in
            MainActor.assumeIsolated {
                guard let self, !self.cards.isEmpty else { return }
                if relayoutKeys.contains(name) { self.screen = nil; self.layout(animated: true) }
                if cardKeys.contains(name) {
                    self.cards.forEach { $0.updateUploadButtonVisibility(); $0.scheduleAutoClose() }
                }
            }
        }
    }

    // MARK: QuickAccessServicing

    var hasOverlays: Bool { !cards.isEmpty }

    func show(_ media: CapturedMedia) {
        isSlidDown = false
        if let existing = cards.first(where: { $0.media.id == media.id }) {
            // Already on screen: move it to the newest slot.
            cards.removeAll { $0 === existing }
            cards.insert(existing, at: 0)
            layout(animated: true)
            return
        }
        recentlyClosed.removeAll { $0.id == media.id }
        let card = QuickAccessCard(media: media)
        cards.insert(card, at: 0)
        startDisplayTracking()
        layout(animated: true, appearing: card)
    }

    func remove(_ media: CapturedMedia) {
        cards.first { $0.media.id == media.id }?.close(recordForRestore: false)
    }

    func closeAll() {
        guard !cards.isEmpty else { return }
        if cards.contains(where: { !$0.media.isSaved }) {
            let info = Defaults[.historyEnabled]
                ? "Unsaved captures stay available in Capture History."
                : "Some captures haven't been saved yet."
            guard Alerts.confirm("Do you want to close all overlays?", info: info, confirmTitle: "Close All") else { return }
        }
        cards.forEach { $0.close(recordForRestore: true) }
    }

    /// Slides the stack down out of the way (swipe down / "Temporarily Hide"); hovering the peeking card restores it.
    func slideDown() {
        guard !cards.isEmpty, !isSlidDown else { return }
        isSlidDown = true
        cards.forEach { $0.setHovered(false) }
        layout(animated: true)
    }

    func cardWasHovered(_ card: QuickAccessCard) {
        guard isSlidDown else { return }
        isSlidDown = false
        layout(animated: true)
    }

    func saveAll() {
        for card in cards where !card.isUploading {
            if MediaPipeline.save(card.media, askForDestination: false) != nil { card.close(recordForRestore: true) }
        }
    }

    // MARK: Internal API

    /// Re-shows the most recently closed card whose file still exists. Returns false if there is none.
    func restoreLastClosed() -> Bool {
        while let media = recentlyClosed.popLast() {
            if FileManager.default.fileExists(atPath: media.url.path) { show(media); return true }
        }
        return false
    }

    func isShowing(_ media: CapturedMedia) -> Bool { cards.contains { $0.media.id == media.id } }

    /// Closes the card (if any) and forgets the media for restore (used after Move to Trash).
    func removeWithoutRestore(_ media: CapturedMedia) {
        recentlyClosed.removeAll { $0.id == media.id }
        remove(media)
    }

    func cardDidClose(_ card: QuickAccessCard, recordForRestore: Bool) {
        cards.removeAll { $0 === card }
        if recordForRestore {
            recentlyClosed.removeAll { $0.id == card.media.id }
            recentlyClosed.append(card.media)
            if recentlyClosed.count > maxRecentlyClosed { recentlyClosed.removeFirst(recentlyClosed.count - maxRecentlyClosed) }
        }
        let panel = card.panel
        if panel.isVisible {
            let out = QuickAccessLayout.offscreenFrame(for: panel.frame, in: (panel.screen ?? NSScreen.active).visibleFrame,
                                                       side: Defaults[.quickAccessSide])
            let reduceMotion = OverlayStyle.reduceMotion
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = reduceMotion ? 0.18 : 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.6)
                if !reduceMotion { panel.animator().setFrame(out, display: true) }
                panel.animator().alphaValue = 0
            }, completionHandler: {
                // `card` is captured so the panel stays alive until the animation finishes.
                MainActor.assumeIsolated { card.panel.orderOut(nil) }
            })
        } else {
            panel.orderOut(nil)
        }
        if cards.isEmpty { stopDisplayTracking(); isSlidDown = false }
        layout(animated: true)
    }

    // MARK: Layout

    private func targetScreen() -> NSScreen {
        if let s = screen, NSScreen.screens.contains(s) { return s }
        // "Main screen" is the primary display (the one with the menu bar), not the key window's screen.
        let s = Defaults[.quickAccessScreen] == .mainScreen ? (NSScreen.screens.first ?? NSScreen.active) : NSScreen.active
        screen = s
        return s
    }

    private func layout(animated: Bool, appearing: QuickAccessCard? = nil) {
        guard !cards.isEmpty else { hideHeader(); return }
        let visible = targetScreen().visibleFrame
        let side = Defaults[.quickAccessSide]
        let scale = Defaults[.quickAccessSize]
        let sizes = cards.map { QuickAccessLayout.cardSize(for: $0.media.pixelSize, scale: scale) }
        let result = QuickAccessLayout.layout(newestFirst: sizes, in: visible, side: side, scale: scale)

        for (index, (card, slot)) in zip(cards, result.cards).enumerated() {
            let panel = card.panel
            var frame = slot
            if isSlidDown, let f = slot { frame = index == 0 ? QuickAccessLayout.slidDownFrame(for: f, in: visible) : nil }
            card.targetFrame = frame
            guard let frame else {
                // Older cards: no room, or the stack is slid down.
                if panel.isVisible { fadeOut(panel) }
                continue
            }
            if card === appearing {
                let source = card.media.captureRect
                card.media.captureRect = nil   // only meaningful right after the capture (not on restore)
                if let source, !OverlayStyle.reduceMotion {
                    handOff(card, from: source, to: frame, in: visible, side: side)
                } else {
                    slideIn(card, to: frame, in: visible, side: side)
                }
            } else if card.isHandingOff {
                panel.setFrame(frame, display: false)   // still transparent: the flight reveals it
            } else if !panel.isVisible || (panel.alphaValue < 1 && !card.isDragging) {
                panel.setFrame(frame, display: false)
                if !panel.isVisible { panel.alphaValue = 0 }
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
            } else if panel.frame != frame {
                if animated && !OverlayStyle.reduceMotion {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.3
                        ctx.timingFunction = OverlayStyle.easeOut
                        panel.animator().setFrame(frame, display: true)
                    }, completionHandler: { MainActor.assumeIsolated { self.layoutDidSettle() } })
                } else {
                    panel.setFrame(frame, display: true)
                }
            }
        }
        if !isSlidDown, let hf = result.header { showHeader(at: hf, animated: animated) } else { hideHeader() }
        if !animated { layoutDidSettle() }
    }

    /// First appearance: slides in from the screen edge with a slight overshoot (a fade with Reduce Motion).
    private func slideIn(_ card: QuickAccessCard, to frame: CGRect, in visible: CGRect, side: ScreenSide) {
        let panel = card.panel
        let reduceMotion = OverlayStyle.reduceMotion
        panel.setFrame(reduceMotion ? frame : QuickAccessLayout.offscreenFrame(for: frame, in: visible, side: side), display: false)
        panel.alphaValue = reduceMotion ? 0 : 1
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            if reduceMotion {
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            } else {
                ctx.duration = 0.35
                ctx.timingFunction = OverlayStyle.springTiming
                panel.animator().setFrame(frame, display: true)
            }
        }, completionHandler: { MainActor.assumeIsolated { self.layoutDidSettle() } })
    }

    /// CleanShot-style hand-off: the captured image appears exactly where it was captured and flies into the
    /// card's slot; the (transparent, already placed) card then takes over in the same frame.
    private func handOff(_ card: QuickAccessCard, from source: CGRect, to frame: CGRect, in visible: CGRect, side: ScreenSide) {
        let panel = card.panel
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        card.isHandingOff = true
        let finish = { [weak self] (flown: Bool) in
            card.isHandingOff = false
            guard let self, !card.isClosing, self.cards.contains(where: { $0 === card }) else { return }
            if flown { panel.alphaValue = 1 } else { self.slideIn(card, to: card.targetFrame ?? frame, in: visible, side: side) }
            self.layoutDidSettle()
        }
        CaptureFlight.fly(media: card.media, from: source, to: frame, radius: OverlayStyle.cardCornerRadius,
                          // The flight may only end once the card can show the same picture (no blank flash).
                          land: { reveal in card.whenThumbnailReady { reveal() } },
                          isCancelled: { card.isClosing },
                          completion: finish)
    }

    /// Fades a card that lost its slot; the order-out is skipped if a later layout gave it a slot again.
    private func fadeOut(_ panel: OverlayPanel) {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                guard let card = self.cards.first(where: { $0.panel === panel }), card.targetFrame == nil else { return }
                panel.orderOut(nil)
            }
        })
    }

    /// Cards that moved under a still pointer (or away from it) get no tracking events: re-derive hover state.
    private func layoutDidSettle() {
        for card in cards {
            card.panel.invalidateShadow()
            card.syncHoverWithPointer()
        }
    }

    // MARK: Header (Close All / Save All)

    private func showHeader(at frame: CGRect, animated: Bool) {
        let panel: OverlayPanel
        if let h = header { panel = h } else {
            panel = OverlayWindow.makePanel(frame, level: OverlayWindow.quickAccessLevel)
            panel.contentView = makeHeaderView()
            header = panel
        }
        if panel.isVisible && animated {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.22; panel.animator().setFrame(frame, display: true) }
        } else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
    }

    private func hideHeader() {
        header?.orderOut(nil)
    }

    private func makeHeaderView() -> NSView {
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.maskImage = .roundedMask(radius: OverlayStyle.cardCornerRadius * 0.75)
        let closeAll = HeaderButton(title: "Close All") { [weak self] in self?.closeAll() }
        let saveAll = HeaderButton(title: "Save All") { [weak self] in self?.saveAll() }
        closeAll.toolTip = "Close All Overlays"
        saveAll.toolTip = "Save All Overlays"
        let stack = NSStackView(views: [closeAll, saveAll])
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: fx.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -3),
        ])
        return fx
    }

    // MARK: Following the active display

    private func startDisplayTracking() {
        guard displayTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCurrentDisplay() }
        }
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }

    private func stopDisplayTracking() {
        displayTimer?.invalidate()
        displayTimer = nil
        screen = nil
    }

    private func checkCurrentDisplay() {
        cards.forEach { $0.syncHoverWithPointer() }
        guard Defaults[.quickAccessScreen] == .activeScreen, NSScreen.screens.count > 1,
              !cards.contains(where: { $0.isHovered || $0.isUploading }), NSEvent.pressedMouseButtons == 0 else { return }
        let active = NSScreen.active
        guard active != screen else { return }
        screen = active
        layout(animated: false)
    }

    // MARK: Media changes

    private func mediaDidChange(_ media: CapturedMedia) {
        guard let card = cards.first(where: { $0.media.id == media.id }) else { return }
        card.mediaDidChange()
        layout(animated: true)   // aspect may have changed (e.g. cropped in Annotate)
    }
}

/// Compact text button for the stack header.
private final class HeaderButton: NSButton {
    private let handler: () -> Void
    private var hoverArea: NSTrackingArea?
    private var hovering = false { didSet { layer?.backgroundColor = NSColor.white.withAlphaComponent(hovering ? 0.18 : 0).cgColor } }

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        target = self
        action = #selector(run)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTracking(on: self, existing: &hoverArea)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    @objc private func run() { handler() }
}
