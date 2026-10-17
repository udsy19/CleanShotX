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

    var isShowing: Bool { !covers.isEmpty }
    /// Window numbers of the covers, to keep them in ScreenCaptureKit captures.

    func setUserHidden(_ hidden: Bool) {
        userHidden = hidden
        Task { await update() }
    }

    /// Shows the covers for the duration of a capture (no-op unless the preference is on) and waits until
    /// they are on screen. Balance with `endTemporaryHide()`.
    func beginTemporaryHide() async -> Bool {
        guard Defaults[.hideDesktopIconsWhileCapturing] else { return false }
        temporaryHolds += 1
        await update()
        // Let the window server composite the new windows before pixels are read.
        try? await Task.sleep(nanoseconds: 60_000_000)
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
        for (id, w) in covers where !ids.contains(id) { w.orderOut(nil); w.close(); covers[id] = nil }
        for screen in screens {
            let image = await WallpaperProvider.iconCoverImage(for: screen)
            // A newer rebuild or a tear-down happened while rendering.
            guard generation == renderGeneration, shouldShow else { return }
            let cover = covers[screen.displayID] ?? IconCoverWindow()
            covers[screen.displayID] = cover
            cover.show(on: screen, image: image, color: Defaults[.wallpaperColor])
        }
    }

    private func tearDown() {
        renderGeneration += 1
        for w in covers.values { w.orderOut(nil); w.close() }
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

/// Borderless, non-activating window that paints the wallpaper over the desktop icons of one screen.
@MainActor
private final class IconCoverWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        backgroundColor = .black
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(on screen: NSScreen, image: CGImage?, color: RGBAColor) {
        setFrame(screen.frame, display: false)
        let layer = contentView?.layer
        layer?.contents = image
        layer?.contentsScale = screen.backingScaleFactor
        layer?.backgroundColor = color.cgColor
        orderFrontRegardless()
    }
}
