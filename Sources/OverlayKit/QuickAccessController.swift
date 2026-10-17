import AppKit
import Combine
import SuperScreenshotCore

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
        let relayoutKeys: Set<String> = [Defaults.Keys.quickAccessSide.name, Defaults.Keys.quickAccessSizeIndex.name,
                                         Defaults.Keys.quickAccessScreen.name]
        let cardKeys: Set<String> = [Defaults.Keys.quickAccessShowUploadButton.name, Defaults.Keys.quickAccessAutoClose.name,
                                     Defaults.Keys.quickAccessAutoCloseSeconds.name]
        defaultsSub = Defaults.changes.receive(on: DispatchQueue.main).sink { [weak self] name in
            MainActor.assumeIsolated {
                guard let self, !self.cards.isEmpty else { return }
                if name == Defaults.Keys.quickAccessSizeIndex.name { self.cards.forEach { $0.updateCornerButtonSize() } }
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
        layout(animated: true)
        // Like CleanShot, the card slides in from the screen edge (the capture doesn't fly into it); it waits for its
        // thumbnail so it never enters blank.
        card.whenThumbnailReady { [weak self, weak card] in
            guard let self, let card else { return }
            self.enter(card)
        }
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
            // Exit (measured): slide 69 pt toward the edge while fading out, ease-in. `card` is captured so its panel
            // stays alive until the fade ends.
            let curve = PanelMotion.Curve.easeIn(QuickAccessMotion.disappearDuration)
            PanelMotion.shared.fade(panel, to: 0, curve: curve) { _ in card.panel.orderOut(nil) }
            if !OverlayStyle.reduceMotion {
                // From wherever it is (a swipe may already have pulled it toward the edge).
                PanelMotion.shared.move(panel, to: QuickAccessLayout.edgeFrame(for: panel.frame, side: Defaults[.quickAccessSide]),
                                        curve: curve)
            }
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

    private func layout(animated: Bool) {
        guard !cards.isEmpty else { hideHeader(); return }
        let screen = targetScreen()
        let visible = screen.visibleFrame
        let size = QuickAccessLayout.cardSize(sizeIndex: Defaults[.quickAccessSizeIndex])
        let result = QuickAccessLayout.layout(count: cards.count, cardSize: size, screen: screen.frame, visible: visible,
                                              side: Defaults[.quickAccessSide])
        let motion = PanelMotion.shared
        let spring = animated && !OverlayStyle.reduceMotion

        for (index, (card, slot)) in zip(cards, result.cards).enumerated() {
            let panel = card.panel
            var frame = slot
            if isSlidDown, let f = slot { frame = index == 0 ? QuickAccessLayout.slidDownFrame(for: f, in: visible) : nil }
            card.targetFrame = frame
            guard card.hasEntered else { continue }   // its entrance starts once the thumbnail is ready
            guard let frame else {
                // Older cards: no room, or the stack is slid down.
                if panel.isVisible && motion.alphaTarget(of: panel) != 0 { fadeOut(panel) }
                continue
            }
            if !panel.isVisible || ((motion.alphaTarget(of: panel) ?? panel.alphaValue) < 1 && !card.isDragging) {
                // (Re)gained a slot: fade in place.
                motion.place(panel, at: frame)
                if !panel.isVisible { panel.alphaValue = 0 }
                panel.orderFrontRegardless()
                motion.fade(panel, to: 1, curve: .easeOut(0.2))
            } else if (motion.destination(of: panel) ?? panel.frame) != frame {
                // Reflow (a card closed, the stack slid down, settings changed): the entrance spring.
                if spring {
                    motion.move(panel, to: frame, curve: .spring) { [weak self] done in if done { self?.layoutDidSettle() } }
                } else {
                    motion.place(panel, at: frame)
                }
            }
        }
        if !isSlidDown, let hf = result.header { showHeader(at: hf, animated: animated) } else { hideHeader() }
        if !animated { layoutDidSettle() }
    }

    /// First appearance (measured): from 69 pt toward the screen edge and transparent, the card springs to its slot
    /// (≈ 5 pt overshoot at 0.19 s, settled by ≈ 0.3 s) while fading in over 0.25 s. A plain fade with Reduce Motion.
    private func enter(_ card: QuickAccessCard) {
        guard !card.hasEntered, !card.isClosing, cards.contains(where: { $0 === card }) else { return }
        card.hasEntered = true
        guard let frame = card.targetFrame else { return }   // no slot right now: a later layout fades it in
        let panel = card.panel
        let reduceMotion = OverlayStyle.reduceMotion
        panel.setFrame(reduceMotion ? frame : QuickAccessLayout.edgeFrame(for: frame, side: Defaults[.quickAccessSide]), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let motion = PanelMotion.shared
        if reduceMotion {
            motion.fade(panel, to: 1, curve: .easeOut(0.2)) { [weak self] _ in self?.layoutDidSettle() }
        } else {
            motion.move(panel, to: frame, curve: .spring) { [weak self] done in if done { self?.layoutDidSettle() } }
            motion.fade(panel, to: 1, curve: .easeOut(QuickAccessMotion.appearFadeDuration))
        }
    }

    /// Fades a card that lost its slot; the order-out is skipped if a later layout gave it a slot again.
    private func fadeOut(_ panel: OverlayPanel) {
        PanelMotion.shared.fade(panel, to: 0, curve: .easeIn(0.18)) { [weak self] done in
            guard done, let self, let card = self.cards.first(where: { $0.panel === panel }), card.targetFrame == nil else { return }
            panel.orderOut(nil)
        }
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
