import AppKit
import Carbon.HIToolbox
import ShotcraftCore

// Pure, UI-free logic behind the Settings panes. Kept nonisolated so the self-tests can exercise it headlessly.

// MARK: - Panes

/// Sidebar panes in CleanShot X 5.0 order; `about` sits apart at the bottom of the sidebar.
public enum PreferencesPane: String, CaseIterable, Identifiable, Sendable {
    case general, shortcuts, quickAccess, wallpaper, screenshots, recording, annotate, upload, advanced, about

    public var id: String { rawValue }

    /// Panes listed in the main sidebar list (About is pinned below it).
    public static var sidebarPanes: [PreferencesPane] { allCases.filter { $0 != .about } }

    public var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .quickAccess: "Quick Access"
        case .wallpaper: "Wallpaper"
        case .screenshots: "Screenshots"
        case .recording: "Screen Recording"
        case .annotate: "Annotate"
        case .upload: "Upload"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    /// White glyph drawn on the pane's coloured sidebar tile.
    public var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "command"
        case .quickAccess: "rectangle.and.hand.point.up.left.fill"
        case .wallpaper: "square.on.square"
        case .screenshots: "camera.fill"
        case .recording: "video.fill"
        case .annotate: "pencil"
        case .upload: "cloud.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: "info"
        }
    }

    /// Resolves an external identifier (URL scheme `tab=`, `show(pane:)`) case-insensitively, with aliases for
    /// CleanShot's own tab names.
    public init?(identifier: String?) {
        guard let raw = identifier?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let compact = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if let match = PreferencesPane.allCases.first(where: { $0.rawValue.lowercased() == compact }) {
            self = match; return
        }
        switch compact {
        case "screenrecording", "video", "videos": self = .recording
        case "screenshot": self = .screenshots
        case "cloud", "uploads", "uploading": self = .upload
        case "quickaccessoverlay", "overlay": self = .quickAccess
        case "hotkeys", "keyboard": self = .shortcuts
        case "desktop", "background": self = .wallpaper
        case "annotation", "editor": self = .annotate
        default: return nil
        }
    }
}

/// Builds popup-button choice lists that always contain the stored value, even a non-standard one.
public enum PickerChoices {
    /// `base` unchanged when it contains `value`; otherwise `value` is inserted before the first larger entry
    /// (0, which means "original"/"forever", is never treated as larger).
    public static func including(_ value: Int, in base: [Int]) -> [Int] {
        guard !base.contains(value) else { return base }
        var out = base
        let index = out.firstIndex { $0 != 0 && $0 > value } ?? out.endIndex
        out.insert(value, at: index)
        return out
    }
}

// MARK: - After-capture actions

public enum AfterCaptureRules {
    public static let atLeastOneTitle = "At least one action needs to be enabled"
    public static let atLeastOneMessage = "Please select at least one thing that should happen after capturing your screen."

    public static let screenshotChoices: [AfterCaptureAction] = [.showQuickAccess, .copyToClipboard, .save, .annotate, .upload, .pin]
    public static let recordingChoices: [AfterCaptureAction] = [.showQuickAccess, .copyToClipboard, .save, .upload, .openVideoEditor]

    /// Rows of the General → After Capture table (Action | Screenshot | Recording), in CleanShot's order.
    public static let tableRows: [AfterCaptureAction] = [.showQuickAccess, .copyToClipboard, .save, .upload, .annotate, .pin, .openVideoEditor]

    /// Row title; "Upload" names our own upload destinations instead of CleanShot Cloud.
    public static func title(for action: AfterCaptureAction) -> String {
        action == .upload ? "Upload & copy link" : action.displayName
    }

    /// Returns the new set, or nil when the change would leave no action enabled (the change is refused).
    public static func toggling(_ action: AfterCaptureAction, on: Bool, in current: Set<AfterCaptureAction>) -> Set<AfterCaptureAction>? {
        var next = current
        if on { next.insert(action) } else { next.remove(action) }
        return next.isEmpty ? nil : next
    }
}

// MARK: - Shortcuts

public enum ShortcutPlanner {
    /// macOS screenshot shortcuts suggested by "Use System Default Shortcuts".
    public static var systemDefaultAssignments: [(action: AppAction, shortcut: Shortcut)] {
        let cs: NSEvent.ModifierFlags = [.command, .shift]
        return [(.captureFullscreen, Shortcut(key: kVK_ANSI_3, modifiers: cs)),
                (.captureArea, Shortcut(key: kVK_ANSI_4, modifiers: cs)),
                (.allInOne, Shortcut(key: kVK_ANSI_5, modifiers: cs))]
    }

    /// Only All-In-One on ⇧⌘5 (the macOS "Screenshot and recording options" equivalent).
    public static var allInOneOnlyAssignment: [(action: AppAction, shortcut: Shortcut)] {
        systemDefaultAssignments.filter { $0.action == .allInOne }
    }

    /// Effective shortcut of every action given the stored map (missing = action default, explicit nil = cleared).
    public static func effective(_ stored: [String: Shortcut?]) -> [AppAction: Shortcut] {
        var out: [AppAction: Shortcut] = [:]
        for action in AppAction.allCases {
            let s: Shortcut? = stored[action.rawValue] ?? action.defaultShortcut
            if let s { out[action] = s }
        }
        return out
    }

    /// The action (other than `excluding`) that already uses `shortcut`.
    public static func conflict(for shortcut: Shortcut, excluding: AppAction?, in effective: [AppAction: Shortcut]) -> AppAction? {
        AppAction.allCases.first { $0 != excluding && effective[$0] == shortcut }
    }

    /// Shortcuts assigned to more than one action.
    public static func duplicates(in effective: [AppAction: Shortcut]) -> [Shortcut: [AppAction]] {
        var byShortcut: [Shortcut: [AppAction]] = [:]
        for action in AppAction.allCases { if let s = effective[action] { byShortcut[s, default: []].append(action) } }
        return byShortcut.filter { $0.value.count > 1 }
    }

    /// Applies `assignments` to the stored map; any other action that would collide is cleared (explicit nil).
    public static func applying(_ assignments: [(action: AppAction, shortcut: Shortcut)],
                                to stored: [String: Shortcut?]) -> [String: Shortcut?] {
        var next = stored
        let assigned = Set(assignments.map(\.action))
        let current = effective(stored)
        for (action, shortcut) in assignments {
            for other in AppAction.allCases where !assigned.contains(other) && current[other] == shortcut {
                next[other.rawValue] = .some(nil)
            }
            next[action.rawValue] = .some(shortcut)
        }
        return next
    }

    /// True when every assignment is already in effect.
    public static func isApplied(_ assignments: [(action: AppAction, shortcut: Shortcut)], in stored: [String: Shortcut?]) -> Bool {
        let e = effective(stored)
        return assignments.allSatisfy { e[$0.action] == $0.shortcut }
    }

    /// Search filter for the Shortcuts pane: matches title, group, URL command or the shortcut's display string.
    public static func filter(_ actions: [AppAction], query: String, display: (AppAction) -> String = { _ in "" }) -> [AppAction] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return actions }
        let words = q.split(separator: " ").map(String.init)
        return actions.filter { a in
            let hay = "\(a.title) \(ShortcutGroup(a).title) \(a.urlCommand) \(display(a))".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// Groups in the Shortcuts pane's display order; empty groups are dropped.
    public static func grouped(_ actions: [AppAction]) -> [(group: ShortcutGroup, actions: [AppAction])] {
        let groups = Dictionary(grouping: actions, by: ShortcutGroup.init)
        return ShortcutGroup.allCases.compactMap { g in groups[g].map { (g, $0) } }
    }
}

/// Shortcuts-pane sections (CleanShot 5.0: General, Screenshots, Screen Recording, Scrolling Capture, OCR,
/// Quick Access Overlay, Annotate). Pane layout only; independent of Core's `AppAction.group`.
public enum ShortcutGroup: String, CaseIterable, Sendable {
    case general, screenshots, recording, scrolling, text, overlays, annotate

    public init(_ action: AppAction) {
        switch action {
        case .allInOne, .toggleDesktopIcons, .openHistory, .restoreLastCapture, .colorPicker, .openPreferences: self = .general
        case .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer,
             .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndUpload, .captureAreaAndAnnotate, .captureAreaAndPin:
            self = .screenshots
        case .recordScreen, .recordGIF, .recordStudio: self = .recording
        case .scrollingCapture: self = .scrolling
        case .captureText: self = .text
        case .pinScreenshot, .pinLast, .togglePins, .closeAllOverlays: self = .overlays
        case .openAnnotate, .openFromClipboard, .annotateLast: self = .annotate
        }
    }

    public var title: String {
        switch self {
        case .general: "General"
        case .screenshots: "Screenshots"
        case .recording: "Screen Recording"
        case .scrolling: "Scrolling Capture"
        case .text: "OCR"
        case .overlays: "Quick Access Overlay & Pins"
        case .annotate: "Annotate"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .screenshots: "camera"
        case .recording: "video"
        case .scrolling: "arrow.up.and.down.text.horizontal"
        case .text: "text.viewfinder"
        case .overlays: "pin"
        case .annotate: "pencil"
        }
    }
}

/// Reads whether the macOS screenshot shortcuts are still active (`com.apple.symbolichotkeys`).
public enum SystemScreenshotHotkeys {
    /// 28 ⇧⌘3, 29 ⌃⇧⌘3, 30 ⇧⌘4, 31 ⌃⇧⌘4, 184 ⇧⌘5.
    public static let ids = [28, 29, 30, 31, 184]

    /// Parses an `AppleSymbolicHotKeys` dictionary. Entries missing from the dictionary are enabled by default.
    public static func enabledIDs(in symbolicHotKeys: [String: Any]?) -> Set<Int> {
        Set(ids.filter { id in
            guard let entry = symbolicHotKeys?[String(id)] as? [String: Any] else { return true }
            if let b = entry["enabled"] as? Bool { return b }
            if let n = entry["enabled"] as? NSNumber { return n.boolValue }
            return true
        })
    }

    /// The symbolic-hotkey id macOS uses for `shortcut`, if it is one of its screenshot shortcuts.
    public static func id(for shortcut: Shortcut) -> Int? {
        let m = shortcut.modifiers.intersection([.command, .shift, .control, .option])
        let plain: NSEvent.ModifierFlags = [.command, .shift]
        let withControl: NSEvent.ModifierFlags = [.command, .shift, .control]
        switch Int(shortcut.keyCode) {
        case kVK_ANSI_3: return m == plain ? 28 : m == withControl ? 29 : nil
        case kVK_ANSI_4: return m == plain ? 30 : m == withControl ? 31 : nil
        case kVK_ANSI_5: return m == plain ? 184 : nil
        default: return nil
        }
    }

    /// Actions whose shortcut macOS will intercept because the matching system shortcut is still enabled.
    public static func shadowedActions(effective: [AppAction: Shortcut], enabledIDs: Set<Int>) -> [AppAction] {
        AppAction.allCases.filter { a in effective[a].flatMap(id(for:)).map(enabledIDs.contains) ?? false }
    }

    public static func currentEnabledIDs() -> Set<Int> {
        let dict = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        return enabledIDs(in: dict)
    }

    public static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!
}

// MARK: - Restore defaults

public enum PreferencesReset {
    /// Every user-facing preference "Restore Defaults" resets. Excludes onboarding state and remembered areas.
    public static let restorableKeys: [Defaults.Keys] = [
        Defaults.Keys.launchAtLogin, .showMenuBarIcon, .playSounds, .captureSound, .exportLocation,
        .afterScreenshotActions, .afterRecordingActions, .hideDesktopIconsWhileCapturing, .clipboardContent,
        .wallpaperSource, .customWallpaperPath, .wallpaperColor, .updateWallpaperOnSpaceChange,
        .screenshotFormat, .jpegQuality, .scaleRetinaScreenshotsTo1x, .convertToSRGB, .addBorderToScreenshots,
        .showCursorOnScreenshots, .freezeScreenWhenCapturing, .crosshairMode, .showMagnifier, .rememberLastSelection,
        .selfTimerSeconds, .captureWindowShadow, .windowBackgroundStyle, .windowBackgroundColor, .windowBackgroundPadding,
        .fileNameTemplate, .askForNameAfterCapture,
        .quickAccessSide, .quickAccessScreen, .quickAccessSize, .quickAccessAutoClose, .quickAccessAutoCloseSeconds,
        .quickAccessAutoCloseAction, .quickAccessCloseAfterDragging, .quickAccessCloseAfterUploading,
        .quickAccessSaveBehavior, .quickAccessShowUploadButton,
        .videoFormat, .videoFPS, .videoQuality, .scaleRetinaVideosTo1x, .gifFPS, .gifMaxWidth, .recordShowCursor,
        .recordHighlightClicks, .clickHighlightColor, .recordShowKeystrokes, .recordHideCursorWhenNotMoving,
        .recordDimScreen, .recordShowControls, .recordShowTimeInMenuBar, .recordCountdown, .recordCountdownSeconds,
        .recordMicrophone, .microphoneDeviceID, .recordSystemAudio, .recordAudioMono, .recordCamera, .cameraDeviceID,
        .recordDoNotDisturb, .recordInStudioMode, .rememberLastRecordingArea,
        .annotateAlwaysOnTop, .annotateShowDockIcon, .annotateSmoothDrawing, .annotateShowColorNames,
        .annotateDrawShadow, .annotateExpandCanvas, .annotateInverseArrow, .annotateRememberBackgroundTool,
        .annotateSaveBehavior, .annotateSnapCrop,
        .ocrKeepLineBreaks, .ocrLanguageMode, .ocrLanguages, .ocrOpenLinks,
        .pinLockAndHideOnHover, .pinShowShadow, .historyEnabled, .historyRetentionDays,
        .uploadDestination, .uploadCopyLinkWhenStarts, .uploadMaxImageWidth, .s3Endpoint, .s3Region, .s3Bucket,
        .s3AccessKeyID, .s3PublicURLPrefix, .s3PathPrefix, .customHTTPEndpoint, .customHTTPFieldName,
        .customHTTPHeaders, .customHTTPResponseURLPath, .uploadFolderPath, .uploadFolderURLPrefix,
        .allowURLSchemeAPI, .urlSchemeTrustedApps, .suppressedWarnings, .shortcuts,
    ]

    /// Removes every restorable key from the store and notifies observers. Keychain secrets are kept.
    public static func restoreAll() {
        for key in restorableKeys {
            Defaults.store.removeObject(forKey: key.name)
            Defaults.changes.send(key.name)
        }
    }
}

// MARK: - OCR languages

public enum OCRLanguageSelection {
    /// Localized name of a BCP-47 code, for codes not in the recognizer's list (e.g. a stored code from an older OS).
    public static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code.replacingOccurrences(of: "vi-VT", with: "vi-VN")) ?? code
    }

    /// Toggles a language; the list never becomes empty. Known codes keep the order of `available`
    /// (the recognizer's list); stored codes it doesn't know are kept after them.
    public static func toggling(_ code: String, on: Bool, in current: [String], available: [String]) -> [String] {
        var set = Set(current)
        if on { set.insert(code) } else { set.remove(code) }
        if set.isEmpty { return current }
        let known = available.filter(set.contains)
        let unknown = (current + [code]).filter { set.contains($0) && !available.contains($0) }
        var seen = Set<String>()
        return known + unknown.filter { seen.insert($0).inserted }
    }
}

// MARK: - Window screenshot background

/// Screenshots → Window Screenshots shows two tiles, "With wallpaper" and "Transparent". "With wallpaper" means the
/// background chosen in the Wallpaper pane, so the stored `windowBackgroundStyle` follows `wallpaperSource`.
public enum WindowBackgroundMapping {
    public static func style(for source: WallpaperSource) -> WindowBackgroundStyle {
        switch source {
        case .desktop: .desktopWallpaper
        case .custom: .customWallpaper
        case .color: .color
        }
    }

    /// Writes the "With wallpaper" style (and colour) for the current Wallpaper settings.
    public static func applyWallpaper() {
        let source = Defaults[.wallpaperSource]
        Defaults[.windowBackgroundStyle] = style(for: source)
        if source == .color { Defaults[.windowBackgroundColor] = Defaults[.wallpaperColor] }
    }

    /// Keeps a "With wallpaper" window background in step after the Wallpaper pane changes. Transparent stays.
    public static func syncAfterWallpaperChange() {
        if Defaults[.windowBackgroundStyle] != .transparent { applyWallpaper() }
    }
}

// MARK: - Validation

public enum SettingsValidation {
    /// A problem with an http(s) URL typed into a field, or nil when it's empty or valid.
    public static func urlProblem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return "Not a valid URL." }
        guard scheme == "http" || scheme == "https" else { return "The URL must start with https:// or http://." }
        guard let host = url.host, !host.isEmpty else { return "The URL has no host name." }
        return nil
    }

    /// Popup value used for "Keep history": -1 = disabled, 0 = forever, otherwise days.
    public static func historyChoice(enabled: Bool, days: Int) -> Int { enabled ? max(0, days) : -1 }
}

// MARK: - URL scheme reference

public enum URLSchemeReference {
    public static let commands: [(command: String, summary: String)] = [
        ("all-in-one", "Open All-In-One mode"),
        ("capture-area", "Capture an area (x, y, width, height, display, action)"),
        ("capture-previous-area", "Capture the previously selected area"),
        ("capture-fullscreen", "Capture the whole display (display, action)"),
        ("capture-window", "Capture a window"),
        ("self-timer", "Capture after a countdown"),
        ("scrolling-capture", "Start scrolling capture"),
        ("capture-text", "Recognise text in an area (linebreaks=false)"),
        ("record-screen", "Record a video"),
        ("record-gif", "Record a GIF"),
        ("record-studio", "Record in Studio Mode"),
        ("stop-recording", "Stop the current recording"),
        ("open-annotate", "Open Annotate (filepath)"),
        ("open-from-clipboard", "Annotate the clipboard image"),
        ("pin", "Pin an image (filepath)"),
        ("add-quick-access-overlay", "Show a file in Quick Access (filepath)"),
        ("toggle-desktop-icons", "Toggle desktop icons"),
        ("hide-desktop-icons", "Hide desktop icons"),
        ("show-desktop-icons", "Show desktop icons"),
        ("open-history", "Open Capture History"),
        ("restore-recently-closed", "Restore the last closed capture"),
        ("open-settings", "Open Settings (tab=general, shortcuts, …)"),
        ("close-all-overlays", "Close Quick Access overlays and pins"),
    ]

    public static let examples = [
        "shotcraft://capture-area?action=copy",
        "shotcraft://capture-fullscreen?display=2&action=save",
        "shotcraft://capture-area?x=0&y=0&width=800&height=600&action=annotate",
        "shotcraft://open-settings?tab=shortcuts",
    ]
}

// MARK: - Upload headers editing

public struct HeaderRow: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }

    public static func rows(from dict: [String: String]) -> [HeaderRow] {
        dict.keys.sorted { $0.lowercased() < $1.lowercased() }.map { HeaderRow(name: $0, value: dict[$0] ?? "") }
    }

    /// Rows with an empty name are ignored; later duplicates win.
    public static func dictionary(from rows: [HeaderRow]) -> [String: String] {
        var out: [String: String] = [:]
        for r in rows {
            let n = r.name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { out[n] = r.value }
        }
        return out
    }
}

// MARK: - File-name template editing

public enum TemplateEditing {
    /// Replaces `selection` (UTF-16 range, clamped) in `text` with `token`; returns the new text and caret location.
    public static func inserting(_ token: String, into text: String, replacing selection: NSRange) -> (text: String, caret: Int) {
        let ns = text as NSString
        let loc = min(max(0, selection.location), ns.length)
        let len = min(max(0, selection.length), ns.length - loc)
        let out = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: token)
        return (out, loc + (token as NSString).length)
    }

    /// Replaces each `%i` token with `n` (leaving `%%` escapes intact) so a preview can show a pending counter value.
    public static func substitutingCounter(in template: String, with n: Int) -> String {
        var out = ""
        var it = template.makeIterator()
        while let ch = it.next() {
            guard ch == "%" else { out.append(ch); continue }
            guard let t = it.next() else { out.append("%"); break }
            if t == "i" { out += String(n) } else { out.append("%"); out.append(t) }
        }
        return out
    }

    /// Unknown `%x` sequences in a template (they render literally), for an inline warning.
    public static func unknownTokens(in template: String) -> [String] {
        let known = Set(FileNameTemplate.tokens.map(\.token) + ["%%"])
        var out: [String] = []
        var it = template.makeIterator()
        while let ch = it.next() {
            guard ch == "%" else { continue }
            guard let t = it.next() else { out.append("%"); break }
            let tok = "%\(t)"
            if !known.contains(tok) && !out.contains(tok) { out.append(tok) }
        }
        return out
    }
}

// MARK: - Module-private keys

extension Defaults.Keys {
    static let prefsLastPane = Key<String>("prefs.lastPane", default: PreferencesPane.general.rawValue)
}
