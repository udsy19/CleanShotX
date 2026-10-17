import AppKit
import Combine
import ShotcraftCore

/// Hides desktop icons by covering the desktop of every screen with a wallpaper window placed just above
/// the icon layer (CleanShot: `IconOverlayController` / `IconOverlay`).
@MainActor
final class DesktopIconsController {
    /// The user's "Hide Desktop Icons" toggle.
    private(set) var userHidden = false
    /// Captures currently holding the covers up ("Hide desktop icons while capturing").
    private var temporaryHolds = 0
    private var covers: [CGDirectDisplayID: IconCoverWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?
    private var renderGeneration = 0


    func setUserHidden(_ hidden: Bool) {
        userHidden = hidden
        Task { await update() }
    }

    /// Shows the covers for the duration of a capture (no-op unless the preference is on). With
    /// `waitUntilVisible` it returns once they have faded in and been composited, so pixels read next are
    /// icon-free. Balance with `endTemporaryHide()`.
    func beginTemporaryHide(waitUntilVisible: Bool = true) async -> Bool {
        guard Defaults[.hideDesktopIconsWhileCapturing] else { return false }
        temporaryHolds += 1
        await update()
        if waitUntilVisible {
            // Fade-in plus a frame or two for the window server to composite it.
            let wait = (OverlayMotion.reduced ? 0 : IconCoverWindow.fadeDuration) + 0.05
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        return true
    }

    func endTemporaryHide() {
        temporaryHolds = max(0, temporaryHolds - 1)
        Task { await update() }
    }

    // MARK: Lifecycle

    private var shouldShow: Bool { userHidden || temporaryHolds > 0 }

    private func update() async {
        if shouldShow {
            startObserving()
            if Set(covers.keys) != Set(NSScreen.screens.map(\.displayID)) { await rebuild() }
        } else {
            tearDown()
        }
    }

    private func rebuild() async {
        renderGeneration += 1
        let generation = renderGeneration
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for (id, w) in covers where !ids.contains(id) { w.fadeOutAndClose(); covers[id] = nil }
        for screen in screens {
            let content = await WallpaperProvider.iconCover(for: screen)
            // A newer rebuild or a tear-down happened while rendering.
            guard generation == renderGeneration, shouldShow else { return }
            guard let content else {
                // Never show a desktop that is not the user's: leave this screen's icons visible.
                covers.removeValue(forKey: screen.displayID)?.fadeOutAndClose()
                continue
            }
            let cover = covers[screen.displayID] ?? IconCoverWindow()
            covers[screen.displayID] = cover
            cover.show(on: screen, content: content)
        }
    }

    private func tearDown() {
        renderGeneration += 1
        for w in covers.values { w.fadeOutAndClose() }
        covers.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        for o in observers { center.removeObserver(o); NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        settingsSubscription = nil
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, Defaults[.updateWallpaperOnSpaceChange] else { return }
                    await self.rebuild()
                }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.rebuild() }
            })
        let keys: Set<String> = [Defaults.Keys.wallpaperSource.name, Defaults.Keys.customWallpaperPath.name,
                                 Defaults.Keys.wallpaperColor.name]
        settingsSubscription = Defaults.changes
            .filter { keys.contains($0) }
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.rebuild() } }
    }
}

/// Borderless, non-activating window that paints the wallpaper over the desktop icons of one screen. Its
/// pixels match the live desktop, so fading it in only makes the icons dissolve.
@MainActor
private final class IconCoverWindow: NSPanel {
    static let fadeDuration: TimeInterval = 0.15

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none
        backgroundColor = .clear
        alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(on screen: NSScreen, content: IconCoverContent) {
        setFrame(screen.frame, display: false)
        let layer = contentView?.layer
        switch content {
        case .image(let image):
            layer?.contents = image
            layer?.backgroundColor = nil
        case .color(let color):
            layer?.contents = nil
            layer?.backgroundColor = color.cgColor
        }
        layer?.contentsScale = screen.backingScaleFactor
        let appearing = !isVisible
        orderFrontRegardless()
        if appearing { OverlayMotion.fade(self, to: 1, duration: Self.fadeDuration) }
    }

    func fadeOutAndClose() {
        OverlayMotion.fade(self, to: 0, duration: Self.fadeDuration) { [self] in
            orderOut(nil)
            close()
        }
    }
}
