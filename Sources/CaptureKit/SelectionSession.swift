import AppKit
import Carbon.HIToolbox
import ShotcraftCore

/// How the overlay behaves after the mouse is released.
enum SelectionStyle {
    /// Mouse-up finishes (Capture Area, Capture Window, Self-Timer, OCR).
    case plain
    /// Selection stays with handles + confirm bar (recording, scrolling, Studio).
    case adjustable
    /// Adjustable with the All-In-One size control and mode toolbar.
    case allInOne
}

/// All-In-One toolbar commands that hand the selection to a capture mode.
enum AllInOneCommand {
    case captureArea, scrolling, text, record, gif, selfTimer
}

enum SelectionOutcome {
    /// `lastRect` = the selection at the time of cancelling (for "Remember last selection").
    case cancelled(lastRect: CGRect?)
    case area(CGRect, windowID: CGWindowID?)
    case window(WindowInfo)
    case fullscreen(NSScreen)
    case command(AllInOneCommand, CGRect)
}

struct SelectionConfig {
    var purpose: SelectionPurpose = .screenshot
    var style: SelectionStyle = .plain
    var allowsWindowSelection = true
    var startsInWindowMode = false
    var initialRect: CGRect?
    var showsDimensions = true
    /// Self-Timer: Return / F select the active screen.
    var fullscreenShortcut = false
    /// Frozen screen pixels drawn as background.
    var frozen: FrozenScreens?
    /// Title of the confirm button in `.adjustable` style.
    var confirmTitle = "Capture"
    var initialAspect: AspectRatio = .freeform
}

/// One interactive selection: owns an overlay panel per screen and all shared state
/// (CleanShot: `FSOverlay` / `OneOverlay` + `CrosshairController` + `SnappingController`).
@MainActor
final class SelectionSession {
    enum Mode { case area, window }

    enum Interaction {
        case idle
        /// Mouse down, not moved past the click threshold yet.
        case pending(start: CGPoint)
        case creating(anchor: CGPoint)
        case moving(startRect: CGRect, startPoint: CGPoint)
        case resizing(SelectionHandle, startRect: CGRect)
    }

    let config: SelectionConfig
    private let completion: @MainActor (SelectionOutcome, NSEvent.ModifierFlags) -> Void

    private(set) var mode: Mode
    private(set) var selection: CGRect? { didSet { if selection != oldValue { selectedWindowID = nil } } }
    private var selectedWindowID: CGWindowID?
    private(set) var interaction: Interaction = .idle
    private(set) var hovered: WindowInfo?
    private(set) var cursor: CGPoint = NSEvent.mouseLocation
    private(set) var modifiers: NSEvent.ModifierFlags = []
    private(set) var showsHint = true
    private(set) var aspect: AspectRatio
    /// Pixel source for the magnifier (frozen screens, or a silent snapshot).
    private(set) var pixels: FrozenScreens?
    private let crosshairSetting = Defaults[.crosshairMode]
    /// "To enable magnifier, you must enable Crosshair Mode first."
    private let magnifierSetting = Defaults[.crosshairMode] && Defaults[.showMagnifier]
    private var loadingPixels = false
    private var screenObserver: NSObjectProtocol?

    private var spaceDown = false
    private var lastDragPoint: CGPoint = .zero
    private var finished = false
    private var panels: [OverlayPanel] = []
    private var controls: SelectionControls?
    private let windows: [WindowInfo]
    private let snapXs: [CGFloat]
    private let snapYs: [CGFloat]
    let desktop = ScreenGeometry.desktopFrame

    var isAdjustable: Bool { config.style != .plain }
    var isFinished: Bool { finished }

    init(config: SelectionConfig, completion: @escaping @MainActor (SelectionOutcome, NSEvent.ModifierFlags) -> Void) {
        self.config = config
        self.completion = completion
        self.mode = config.startsInWindowMode && config.allowsWindowSelection ? .window : .area
        self.aspect = config.initialAspect
        self.pixels = config.frozen
        // Windows are needed for hover selection and for edge snapping.
        let wins = SelectionSession.selectableWindows()
        self.windows = wins
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for s in NSScreen.screens { xs += [s.frame.minX, s.frame.maxX]; ys += [s.frame.minY, s.frame.maxY] }
        for w in wins { let f = w.cocoaFrame; xs += [f.minX, f.maxX]; ys += [f.minY, f.maxY] }
        snapXs = xs; snapYs = ys
        if let r = config.initialRect {
            let clamped = r.intersection(desktop)
            if !clamped.isNull, clamped.width >= 1, clamped.height >= 1 {
                selection = clamped
                showsHint = false
            }
        }
    }

    /// Front-to-back on-screen windows that can be picked (normal app windows, panels; no Dock/menu bar).
    static func selectableWindows() -> [WindowInfo] {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let system: Set<String> = ["Dock", "Window Server", "WindowManager", "Control Center", "Notification Center", "Spotlight"]
        return WindowInfo.onScreen().filter { $0.layer >= 0 && $0.layer < dockLevel && !system.contains($0.ownerName) }
    }

    // MARK: Presentation

    func start() {
        let active = NSScreen.active
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen, session: self, frozen: config.frozen?.image(for: screen))
            panels.append(panel)
        }
        if isAdjustable { controls = SelectionControls(session: self) }
        updateHover()
        for p in panels where p.overlayScreenFrame != active.frame { p.orderFrontRegardless() }
        if let key = panels.first(where: { $0.overlayScreenFrame == active.frame }) ?? panels.first {
            key.makeKeyAndOrderFront(nil)
            key.makeFirstResponder(key.overlayView)
        }
        NSCursor.crosshair.set()
        // A display added, removed or rearranged invalidates every panel frame: close the overlay.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        refresh()
        if magnifierSetting { loadMagnifierPixels() }
    }

    /// Snapshot used by the magnifier when the screen is not frozen (own windows are excluded).
    private func loadMagnifierPixels() {
        guard pixels == nil, !loadingPixels else { return }
        loadingPixels = true
        Task { [weak self] in
            let shots = try? await CaptureEngine.captureAllScreens()
            guard let self else { return }
            self.loadingPixels = false
            guard let shots, !self.finished else { return }
            self.pixels = shots
            self.refresh()
        }
    }

    func cancel() { finish(.cancelled(lastRect: selection)) }

    private func finish(_ outcome: SelectionOutcome) {
        guard !finished else { return }
        finished = true
        let mods = NSEvent.modifierFlags
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        controls?.tearDown()
        for p in panels { p.tearDown() }
        // `finish` usually runs inside one of these panels' event dispatch: release them on the next turn.
        let retired = (panels, controls)
        panels.removeAll()
        controls = nil
        DispatchQueue.main.async { withExtendedLifetime(retired) {} }
        NSCursor.arrow.set()
        completion(outcome, mods)
    }

    /// Redraws every overlay and re-lays out the controls.
    func refresh() {
        for p in panels { p.overlayView.needsDisplay = true }
        controls?.layout()
    }

    var panelsForControls: [OverlayPanel] { panels }

    // MARK: Derived state

    /// Rect currently highlighted as a hovered window (no selection or window mode).
    var hoverRect: CGRect? {
        guard let hovered else { return nil }
        return hovered.cocoaFrame.intersection(desktop)
    }

    var isInteracting: Bool { if case .idle = interaction { return false } else { return true } }
    var isCreating: Bool { if case .creating = interaction { return true } else { return false } }

    var snappingEnabled: Bool { !modifiers.contains(.command) }

    /// Crosshair Mode, or ⌘ held temporarily (crosshair + magnifier).
    var showsCrosshair: Bool { crosshairSetting || modifiers.contains(.command) }
    var showsMagnifier: Bool { magnifierSetting || modifiers.contains(.command) }

    var isRecordingPurpose: Bool { [.recording, .gifRecording, .studio].contains(config.purpose) }

    /// The "W x H" badge follows the selection while it is drawn, moved or resized.
    var showsDimensionBadge: Bool {
        guard config.showsDimensions else { return false }
        switch interaction {
        case .creating, .moving, .resizing: return true
        case .idle, .pending: return false
        }
    }

    var hintText: String? {
        guard showsHint, selection == nil, !isInteracting else { return nil }
        var parts: [String]
        switch mode {
        case .area:
            switch config.purpose {
            case .recording, .gifRecording, .studio: parts = ["Drag to record a part of the screen."]
            case .scrolling: parts = ["Drag to capture the scrolling part of the screen."]
            case .screenshot, .text: parts = ["Drag to select capture area."]
            }
            if config.allowsWindowSelection && isRecordingPurpose { parts.append("Press Space to select a window.") }
        case .window:
            parts = ["Click a window to capture it.", "Press Space to select an area."]
        }
        if config.fullscreenShortcut { parts.append("Press Return for fullscreen.") }
        return parts.joined(separator: " ")
    }

    func screen(for rect: CGRect) -> NSScreen { screenShowingMost(of: rect) }

    // MARK: Mouse

    func mouseMoved(to p: CGPoint) {
        cursor = p
        updateHover()
        updateCursor()
        refresh()
    }

    func mouseDown(at p: CGPoint, clickCount: Int) {
        cursor = p
        showsHint = false
        lastDragPoint = p
        if isAdjustable, mode == .area, let sel = selection {
            if let h = SelectionGeometry.handle(at: p, in: sel) {
                interaction = .resizing(h, startRect: sel)
            } else if sel.contains(p) {
                if clickCount >= 2 { confirm(); return }
                interaction = .moving(startRect: sel, startPoint: p)
            } else {
                interaction = .pending(start: p)
            }
        } else {
            interaction = .pending(start: p)
        }
        updateCursor()
        refresh()
    }

    func mouseDragged(to p: CGPoint) {
        cursor = p
        switch interaction {
        case .idle:
            return
        case .pending(let start):
            guard hypot(p.x - start.x, p.y - start.y) > SelectionGeometry.clickThreshold else { return }
            mode = .area
            hovered = nil
            selection = nil
            interaction = .creating(anchor: start)
            lastDragPoint = start
            updateDrag(to: p)
        default:
            updateDrag(to: p)
        }
        lastDragPoint = p
        updateCursor()
        refresh()
    }

    func mouseUp(at p: CGPoint) {
        cursor = p
        let previous = interaction
        interaction = .idle
        switch previous {
        case .idle:
            break
        case .pending:
            click(at: p)
        case .creating:
            if let sel = selection, sel.width >= SelectionGeometry.clickThreshold, sel.height >= SelectionGeometry.clickThreshold {
                if config.style == .plain { finish(.area(sel.integral, windowID: nil)); return }
            } else {
                selection = nil
                click(at: p)
            }
        case .moving, .resizing:
            if let sel = selection, sel.width < 1 || sel.height < 1 { selection = nil }
        }
        if finished { return }
        updateHover()
        updateCursor()
        refresh()
    }

    func rightMouseDown() { cancel() }

    private func click(at p: CGPoint) {
        guard config.allowsWindowSelection else { return }
        updateHover()
        guard let w = hovered else { return }
        switch config.style {
        case .plain:
            finish(.window(w))
        case .allInOne where mode == .window:
            finish(.window(w))
        case .adjustable, .allInOne:
            let r = w.cocoaFrame.intersection(desktop)
            guard !r.isNull else { return }
            mode = .area
            selection = r
            selectedWindowID = w.id
            hovered = nil
        }
    }

    private func updateDrag(to rawPoint: CGPoint) {
        let shift = modifiers.contains(.shift), option = modifiers.contains(.option)
        let p = snappingEnabled ? SelectionGeometry.snap(rawPoint, xs: snapXs, ys: snapYs) : rawPoint
        switch interaction {
        case .creating(var anchor):
            if spaceDown {
                anchor.x += rawPoint.x - lastDragPoint.x
                anchor.y += rawPoint.y - lastDragPoint.y
                interaction = .creating(anchor: anchor)
            }
            let ratio: CGFloat? = shift ? 1 : aspect.value
            let r = SelectionGeometry.rect(from: anchor, to: spaceDown ? rawPoint : p, square: false,
                                           fromCenter: option, ratio: ratio)
            selection = r.intersection(desktop).isNull ? nil : r.intersection(desktop)
        case .moving(let start, let startPoint):
            var dx = rawPoint.x - startPoint.x, dy = rawPoint.y - startPoint.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            var r = start.offsetBy(dx: dx, dy: dy)
            if snappingEnabled { r = SelectionGeometry.snapMoving(r, xs: snapXs, ys: snapYs) }
            selection = SelectionGeometry.clamped(r, to: desktop)
        case .resizing(let handle, let start):
            let ratio: CGFloat? = aspect.value ?? (shift && start.height > 0 ? start.width / start.height : nil)
            let r = SelectionGeometry.resize(start, handle: handle, to: p, ratio: ratio, fromCenter: option)
            let clipped = r.intersection(desktop)
            if !clipped.isNull { selection = clipped }
        case .idle, .pending:
            break
        }
    }

    // MARK: Keyboard

    /// Returns true when handled.
    func keyDown(_ event: NSEvent) -> Bool {
        modifiers = event.modifierFlags
        let code = Int(event.keyCode)
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        showsHint = false
        defer { if !finished { refresh() } }

        switch code {
        case kVK_Escape:
            cancel(); return true
        case kVK_Space:
            if event.isARepeat { return true }
            spaceDown = true
            if isInteracting { return true }
            toggleWindowMode()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mode == .window, let w = hovered { finishWindowPick(w); return true }
            if selection != nil { confirm(); return true }
            if config.fullscreenShortcut { finish(.fullscreen(NSScreen.active)); return true }
            NSSound.beep(); return true
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard isAdjustable, !isInteracting, let sel = selection else { return true }
            let step: CGFloat = shift ? 10 : 1
            let dx: CGFloat = code == kVK_LeftArrow ? -step : code == kVK_RightArrow ? step : 0
            let dy: CGFloat = code == kVK_DownArrow ? -step : code == kVK_UpArrow ? step : 0
            selection = SelectionGeometry.nudged(sel, dx: dx, dy: dy, resize: event.modifierFlags.contains(.option), within: desktop)
            return true
        default:
            break
        }

        if config.fullscreenShortcut && chars == "f" { finish(.fullscreen(NSScreen.active)); return true }
        guard config.style == .allInOne, !event.modifierFlags.contains(.command) else { return false }
        switch chars {
        case "a": perform(.captureArea)
        case "f": finish(.fullscreen(NSScreen.active))
        case "w": toggleWindowMode()
        case "s": perform(.scrolling)
        case "o": perform(.text)
        case "r": perform(.record)
        case "g": perform(.gif)
        case "t": perform(.selfTimer)
        default: return false
        }
        return true
    }

    func keyUp(_ event: NSEvent) {
        modifiers = event.modifierFlags
        if Int(event.keyCode) == kVK_Space { spaceDown = false }
    }

    func flagsChanged(_ event: NSEvent) {
        modifiers = event.modifierFlags
        if showsMagnifier { loadMagnifierPixels() }
        if isInteracting, !isPending { updateDrag(to: lastDragPoint) }
        refresh()
    }

    private var isPending: Bool { if case .pending = interaction { return true } else { return false } }

    private func toggleWindowMode() {
        guard config.allowsWindowSelection else { return }
        mode = mode == .area ? .window : .area
        updateHover()
        updateCursor()
    }

    private func finishWindowPick(_ w: WindowInfo) {
        switch config.style {
        case .plain, .allInOne: finish(.window(w))
        case .adjustable: click(at: cursor)
        }
    }

    // MARK: Commands (controls / shortcuts)

    func confirm() {
        guard let sel = selection?.integral, sel.width >= 1, sel.height >= 1 else { NSSound.beep(); return }
        switch config.style {
        case .plain, .adjustable: finish(.area(sel, windowID: selectedWindowID))
        case .allInOne: finish(.command(.captureArea, sel))
        }
    }

    func perform(_ command: AllInOneCommand) {
        guard let sel = selection?.integral, sel.width >= 1, sel.height >= 1 else { NSSound.beep(); return }
        finish(.command(command, sel))
    }

    func captureFullscreen() { finish(.fullscreen(selection.map(screen(for:)) ?? NSScreen.active)) }

    func enterWindowMode() {
        guard mode != .window else { return }
        toggleWindowMode()
        refresh()
    }

    func setAspect(_ a: AspectRatio) {
        aspect = a
        if let sel = selection, a != .freeform {
            selection = SelectionGeometry.applying(a, to: sel, within: screen(for: sel).frame)
        }
        refresh()
    }

    func setSize(_ size: CGSize) {
        guard let sel = selection else { return }
        var s = size
        if let r = aspect.value {
            // Keep the ratio: the edited dimension wins.
            if abs(size.width - sel.width) >= abs(size.height - sel.height) { s.height = size.width / r } else { s.width = size.height * r }
        }
        selection = SelectionGeometry.resized(sel, to: s, within: desktop)
        refresh()
    }

    /// Toggles the selection between the full screen it is on and the previous rect.
    private var rectBeforeFullscreen: CGRect?
    func toggleFullscreenSelection() {
        if let sel = selection, sel == screen(for: sel).frame, let prev = rectBeforeFullscreen {
            selection = prev
            rectBeforeFullscreen = nil
        } else {
            let screen = selection.map(screen(for:)) ?? NSScreen.active
            rectBeforeFullscreen = selection
            selection = screen.frame
            aspect = .freeform
        }
        mode = .area
        refresh()
    }

    var isFullscreenSelection: Bool {
        guard let sel = selection else { return false }
        return sel == screen(for: sel).frame
    }

    // MARK: Hover / cursor

    private func updateHover() {
        guard config.allowsWindowSelection, !isInteracting, mode == .window || selection == nil else {
            hovered = nil; return
        }
        hovered = windows.first { $0.cocoaFrame.contains(cursor) }
    }

    private func updateCursor() {
        if let panel = panels.first(where: { $0.overlayScreenFrame.contains(cursor) }), panel.isOverControl(cursor) {
            NSCursor.arrow.set(); return
        }
        switch interaction {
        case .moving: NSCursor.closedHand.set(); return
        case .resizing(let h, _): Self.cursor(for: h).set(); return
        default: break
        }
        if isAdjustable, mode == .area, let sel = selection, !isInteracting {
            if let h = SelectionGeometry.handle(at: cursor, in: sel) { Self.cursor(for: h).set(); return }
            if sel.contains(cursor) { NSCursor.openHand.set(); return }
        }
        NSCursor.crosshair.set()
    }

    private static func cursor(for h: SelectionHandle) -> NSCursor {
        switch h {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight, .topRight, .bottomLeft:
            if #available(macOS 15.0, *) {
                let pos: NSCursor.FrameResizePosition
                switch h {
                case .topLeft: pos = .topLeft
                case .topRight: pos = .topRight
                case .bottomLeft: pos = .bottomLeft
                default: pos = .bottomRight
                }
                return NSCursor.frameResize(position: pos, directions: .all)
            }
            return .crosshair
        }
    }
}
