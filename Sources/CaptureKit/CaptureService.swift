import AppKit
import ShotcraftCore

extension Defaults.Keys {
    /// All-In-One area restored when "Remember last selection" is on (CleanShot: `lastOneOverlayArea`).
    static let captureKitLastAllInOneArea = Key<CodableRect?>("capturekit.lastAllInOneArea", default: nil)
}

/// `CaptureServicing` implementation (CleanShot: `ScreenCapture` + `ScreenTools`).
@MainActor
final class CaptureService: CaptureServicing {
    private let icons = DesktopIconsController()
    private var session: SelectionSession?
    private var countdown: CountdownController?
    private var colorSampler: NSColorSampler?
    /// True while screens are being frozen before an overlay appears.
    private var preparing = false
    /// Bumped to abandon an overlay that is still being prepared (another selection took over).
    private var prepareGeneration = 0

    // MARK: Desktop icons

    var desktopIconsHidden: Bool { icons.userHidden }
    func setDesktopIconsHidden(_ hidden: Bool) { icons.setUserHidden(hidden) }

    // MARK: Screenshots

    func captureArea(_ options: CaptureOptions) {
        if let rect = options.rect { captureDirect(rect, mode: .area, actions: options.actions); return }
        let config = SelectionConfig(purpose: .screenshot, style: .plain, allowsWindowSelection: true)
        interactive(config, freeze: Defaults[.freezeScreenWhenCapturing]) { [weak self] outcome, mods, frozen in
            await self?.handleScreenshot(outcome, mods: mods, frozen: frozen, areaMode: .area, actions: options.actions)
        }
    }

    func capturePreviousArea(_ options: CaptureOptions) {
        let desktop = ScreenGeometry.desktopFrame
        guard let rect = options.rect ?? Defaults[.lastCaptureArea]?.cgRect,
              !rect.intersection(desktop).isNull, rect.width >= 1, rect.height >= 1 else {
            captureArea(options); return
        }
        captureDirect(rect.intersection(desktop), mode: .previousArea, actions: options.actions)
    }

    func captureFullscreen(_ options: CaptureOptions) {
        guard !toggleOffActiveCapture() else { return }
        let screens = NSScreen.screens
        let screen = options.displayIndex.flatMap { screens.indices.contains($0) ? screens[$0] : nil } ?? NSScreen.active
        captureDirect(screen.frame, mode: .fullscreen, actions: options.actions)
    }

    func captureWindow(_ options: CaptureOptions) {
        if let rect = options.rect { captureDirect(rect, mode: .window, actions: options.actions); return }
        var config = SelectionConfig(purpose: .screenshot, style: .plain, allowsWindowSelection: true)
        config.startsInWindowMode = true
        interactive(config, freeze: Defaults[.freezeScreenWhenCapturing]) { [weak self] outcome, mods, frozen in
            await self?.handleScreenshot(outcome, mods: mods, frozen: frozen, areaMode: .area, actions: options.actions)
        }
    }

    func selfTimer(_ options: CaptureOptions) {
        if let rect = options.rect {
            guard !toggleOffActiveCapture(), Permissions.ensureScreenRecording() else { return }
            Task { await timedCapture(.area(rect, windowID: nil), mods: [], actions: options.actions) }
            return
        }
        var config = SelectionConfig(purpose: .screenshot, style: .plain, allowsWindowSelection: true)
        config.fullscreenShortcut = true
        // The point of a timer is to capture the screen as it will be, so it never freezes.
        interactive(config, freeze: false) { [weak self] outcome, mods, _ in
            await self?.timedCapture(outcome, mods: mods, actions: options.actions)
        }
    }

    func allInOne() {
        var config = SelectionConfig(purpose: .screenshot, style: .allInOne, allowsWindowSelection: true)
        config.initialAspect = AspectRatio(storageString: Defaults[.captureKitLastAspectRatio]) ?? .freeform
        if Defaults[.rememberLastSelection], let r = Defaults[.captureKitLastAllInOneArea]?.cgRect,
           !r.intersection(ScreenGeometry.desktopFrame).isNull {
            config.initialRect = r
        }
        interactive(config, freeze: Defaults[.freezeScreenWhenCapturing]) { [weak self] outcome, mods, frozen in
            await self?.handleAllInOne(outcome, mods: mods, frozen: frozen)
        }
    }

    // MARK: Shared selection API

    func selectArea(_ options: AreaSelectionOptions, completion: @escaping (AreaSelection?) -> Void) {
        session?.cancel()
        countdown?.cancel()
        // An overlay still freezing the screens would otherwise appear on top of this one.
        if preparing { prepareGeneration += 1; preparing = false }
        guard Permissions.ensureScreenRecording() else { completion(nil); return }
        var config = SelectionConfig()
        config.purpose = options.purpose
        config.allowsWindowSelection = options.allowsWindowSelection
        config.initialRect = options.initialRect
        config.showsDimensions = options.showsDimensions
        switch options.purpose {
        case .screenshot, .text: config.style = .plain
        case .recording, .studio: config.style = .adjustable; config.confirmTitle = "Record"
        case .gifRecording: config.style = .adjustable; config.confirmTitle = "Record GIF"
        case .scrolling: config.style = .adjustable; config.confirmTitle = "Start Capture"
        }
        let desktop = ScreenGeometry.desktopFrame
        let s = SelectionSession(config: config) { [weak self] outcome, _ in
            self?.session = nil
            @MainActor func result(_ r: CGRect, _ id: CGWindowID?) -> AreaSelection {
                let rect = r.intersection(desktop).isNull ? r : r.intersection(desktop)
                return AreaSelection(rect: rect, screen: screenShowingMost(of: rect), windowID: id)
            }
            switch outcome {
            case .cancelled: completion(nil)
            case let .area(r, id): completion(result(r, id))
            case let .window(w): completion(result(w.cocoaFrame, w.id))
            case let .fullscreen(screen): completion(AreaSelection(rect: screen.frame, screen: screen))
            case let .command(_, r): completion(result(r, nil))
            }
        }
        session = s
        s.start()
    }

    // MARK: Color picker

    func pickColor() {
        guard colorSampler == nil else { return }
        let sampler = NSColorSampler()
        colorSampler = sampler
        sampler.show { [weak self] color in
            Task { @MainActor in
                self?.colorSampler = nil
                guard let c = color?.usingColorSpace(.sRGB) else { return }
                let hex = SelectionGeometry.hexString(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
                Clipboard.copy(text: hex)
                HUD.show("Copied \(hex)", symbol: "eyedropper")
            }
        }
    }

    // MARK: Flow plumbing

    /// A second trigger while an overlay or countdown is up closes it (hotkey pressed twice).
    private func toggleOffActiveCapture() -> Bool {
        if preparing { return true }
        if let s = session { s.cancel(); return true }
        if let c = countdown { c.cancel(); return true }
        return false
    }

    /// Shows the selection overlay (optionally over frozen screens) with desktop icons hidden when requested,
    /// then runs `handler`; the temporary icon hiding lasts until `handler` returns.
    private func interactive(_ base: SelectionConfig, freeze: Bool,
                             handler: @escaping (SelectionOutcome, NSEvent.ModifierFlags, FrozenScreens?) async -> Void) {
        guard !toggleOffActiveCapture(), Permissions.ensureScreenRecording() else { return }
        preparing = true
        prepareGeneration += 1
        let generation = prepareGeneration
        Task {
            let held = await icons.beginTemporaryHide()
            var config = base
            if freeze {
                do { config.frozen = try await CaptureEngine.captureAllScreens(includeWindows: icons.coverWindowIDs) }
                catch { Log.capture.error("Freeze failed: \(error.localizedDescription, privacy: .public)") }
            }
            guard generation == prepareGeneration else {
                if held { icons.endTemporaryHide() }
                return
            }
            preparing = false
            let frozen = config.frozen
            let s = SelectionSession(config: config) { [weak self] outcome, mods in
                self?.session = nil
                Task { @MainActor in
                    await handler(outcome, mods, frozen)
                    if held { self?.icons.endTemporaryHide() }
                }
            }
            session = s
            s.start()
        }
    }

    /// Captures a rect without any UI (URL API, previous area, fullscreen).
    private func captureDirect(_ rect: CGRect, mode: CaptureMode, actions: Set<AfterCaptureAction>?) {
        guard !preparing, session == nil, Permissions.ensureScreenRecording() else { return }
        Task {
            let held = await icons.beginTemporaryHide()
            await captureRect(rect, frozen: nil, mode: mode, actions: actions)
            if held { icons.endTemporaryHide() }
        }
    }

    private func handleScreenshot(_ outcome: SelectionOutcome, mods: NSEvent.ModifierFlags, frozen: FrozenScreens?,
                                  areaMode: CaptureMode, actions: Set<AfterCaptureAction>?) async {
        switch outcome {
        case .cancelled: break
        case let .area(r, _), let .command(_, r): await captureRect(r, frozen: frozen, mode: areaMode, actions: actions)
        case let .window(w): await captureWindowImage(w, shift: mods.contains(.shift), mode: .window, actions: actions)
        case let .fullscreen(screen): await captureRect(screen.frame, frozen: frozen, mode: .fullscreen, actions: actions)
        }
    }

    private func handleAllInOne(_ outcome: SelectionOutcome, mods: NSEvent.ModifierFlags, frozen: FrozenScreens?) async {
        if Defaults[.rememberLastSelection] {
            switch outcome {
            case let .cancelled(r?): Defaults[.captureKitLastAllInOneArea] = CodableRect(r)
            case let .area(r, _), let .command(_, r): Defaults[.captureKitLastAllInOneArea] = CodableRect(r)
            case .cancelled, .window, .fullscreen: break
            }
        }
        guard case let .command(command, rect) = outcome else {
            await handleScreenshot(outcome, mods: mods, frozen: frozen, areaMode: .allInOne, actions: nil)
            return
        }
        switch command {
        case .captureArea:
            await captureRect(rect, frozen: frozen, mode: .allInOne, actions: nil)
        case .scrolling:
            Services.text?.startScrollingCapture(CaptureOptions(rect: rect))
        case .record:
            Services.recording?.startRecording(.video, rect: rect)
        case .gif:
            Services.recording?.startRecording(.gif, rect: rect)
        case .selfTimer:
            await timedCapture(.area(rect, windowID: nil), mods: mods, actions: nil)
        case .text:
            await recognizeText(in: rect, frozen: frozen)
        }
    }

    /// Self-Timer: countdown over the chosen target, then a live capture.
    private func timedCapture(_ outcome: SelectionOutcome, mods: NSEvent.ModifierFlags, actions: Set<AfterCaptureAction>?) async {
        let target: CGRect
        switch outcome {
        case .cancelled: return
        case let .area(r, _), let .command(_, r): target = r
        case let .window(w): target = w.cocoaFrame
        case let .fullscreen(screen): target = screen.frame
        }
        guard await runCountdown(over: target) else { return }
        if case let .window(w) = outcome {
            await captureWindowImage(w, shift: mods.contains(.shift), mode: .selfTimer, actions: actions)
        } else {
            await captureRect(target, frozen: nil, mode: .selfTimer, actions: actions)
        }
    }

    private func runCountdown(over rect: CGRect) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let c = CountdownController(rect: rect, seconds: Defaults[.selfTimerSeconds]) { [weak self] fired in
                self?.countdown = nil
                cont.resume(returning: fired)
            }
            countdown = c
            c.start()
        }
    }

    // MARK: Pixels → pipeline

    /// Grabs `rect` (from frozen pixels when available) and returns image + scale, alerting on failure.
    private func grab(_ rect: CGRect, frozen: FrozenScreens?) async -> (CGImage, CGFloat)? {
        if let frozen, let cropped = frozen.crop(rect) { return cropped }
        // Let the overlay leave the screen and the previously active windows repaint.
        try? await Task.sleep(nanoseconds: 80_000_000)
        do {
            return try await CaptureEngine.capture(rect: rect, includeWindows: icons.coverWindowIDs)
        } catch {
            Alerts.error("Couldn't capture the screen.", error)
            return nil
        }
    }

    private func captureRect(_ rect: CGRect, frozen: FrozenScreens?, mode: CaptureMode, actions: Set<AfterCaptureAction>?) async {
        let r = rect.integral
        guard r.width >= 1, r.height >= 1 else { return }
        Defaults[.lastCaptureArea] = CodableRect(r)
        guard let (image, scale) = await grab(r, frozen: frozen) else { return }
        MediaPipeline.didCaptureImage(image, scale: scale, mode: mode, actions: actions)
    }

    private func captureWindowImage(_ w: WindowInfo, shift: Bool, mode: CaptureMode, actions: Set<AfterCaptureAction>?) async {
        Defaults[.lastCaptureArea] = CodableRect(w.cocoaFrame.intersection(ScreenGeometry.desktopFrame))
        let shadow = Defaults[.captureWindowShadow]
        do {
            let (image, scale) = try await ScreenCapturer.capture(windowID: w.id, shadow: shadow)
            let style = WindowBackgroundComposer.effectiveStyle(preference: Defaults[.windowBackgroundStyle], shiftHeld: shift)
            let final = await WindowBackgroundComposer.compose(image, scale: scale, style: style,
                                                               screen: screenShowingMost(of: w.cocoaFrame), hasSystemShadow: shadow)
            MediaPipeline.didCaptureImage(final, scale: scale, mode: mode, actions: actions)
        } catch {
            Alerts.error("Couldn't capture the window.", error)
        }
    }

    private func recognizeText(in rect: CGRect, frozen: FrozenScreens?) async {
        guard let text = Services.text else { return }
        guard let (image, _) = await grab(rect.integral, frozen: frozen) else { return }
        text.recognizeText(in: image, keepLineBreaks: Defaults[.ocrKeepLineBreaks]) { result in
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                if trimmed.isEmpty {
                    HUD.show("No text found", symbol: "text.magnifyingglass")
                } else {
                    Clipboard.copy(text: result)
                    HUD.show("Text has been copied")
                }
            }
        }
    }
}
