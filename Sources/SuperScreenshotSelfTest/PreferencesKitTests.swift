import AppKit
import Carbon.HIToolbox
import SuperScreenshotCore
import PreferencesKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
func registerPreferencesKitTests() {
    SelfTest.cases.append(("Prefs.paneIdentifiers", {
        check(PreferencesPane(identifier: "general") == .general, "exact id")
        check(PreferencesPane(identifier: "QuickAccess") == .quickAccess, "case-insensitive")
        check(PreferencesPane(identifier: "quick-access") == .quickAccess, "kebab-case")
        check(PreferencesPane(identifier: "cloud") == .upload, "cloud alias → upload")
        check(PreferencesPane(identifier: "screenrecording") == .recording, "recording alias")
        check(PreferencesPane(identifier: nil) == nil && PreferencesPane(identifier: "") == nil, "empty → nil")
        check(PreferencesPane(identifier: "bogus") == nil, "unknown → nil")
        check(PreferencesPane.allCases.allSatisfy { PreferencesPane(identifier: $0.rawValue) == $0 }, "every id round-trips")
        check(PreferencesPane.sidebarPanes.first == .general && PreferencesPane.sidebarPanes.last == .advanced
              && !PreferencesPane.sidebarPanes.contains(.about), "5.0 sidebar order, About pinned apart")
        check(PreferencesPane.recording.title == "Screen Recording", "recording title")
    }))

    SelfTest.cases.append(("Prefs.pickerChoices", {
        check(PickerChoices.including(5, in: [3, 5, 10]) == [3, 5, 10], "present value keeps list")
        check(PickerChoices.including(7, in: [3, 5, 10]) == [3, 5, 7, 10], "inserted in order")
        check(PickerChoices.including(45, in: [1, 30, 90, 0]) == [1, 30, 45, 90, 0], "0 (forever) stays last")
        check(PickerChoices.including(1000, in: [0, 800, 1280]) == [0, 800, 1000, 1280], "0 (original) stays first")
        check(PickerChoices.including(5000, in: [0, 800]) == [0, 800, 5000], "largest appended")
    }))

    SelfTest.cases.append(("Prefs.validation", {
        check(SettingsValidation.urlProblem("") == nil && SettingsValidation.urlProblem("  ") == nil, "empty is fine")
        check(SettingsValidation.urlProblem("https://s3.example.com") == nil, "https ok")
        check(SettingsValidation.urlProblem("http://localhost:9000/up") == nil, "http with port ok")
        check(SettingsValidation.urlProblem("ftp://x.com") != nil, "non-http scheme rejected")
        check(SettingsValidation.urlProblem("example.com/upload") != nil, "missing scheme rejected")
        check(SettingsValidation.urlProblem("https://") != nil, "missing host rejected")
        check(SettingsValidation.historyChoice(enabled: false, days: 30) == -1, "disabled history → -1")
        check(SettingsValidation.historyChoice(enabled: true, days: 0) == 0, "forever")
        check(SettingsValidation.historyChoice(enabled: true, days: 7) == 7, "days")
    }))

    SelfTest.cases.append(("Prefs.windowBackground", {
        let suite = UserDefaults(suiteName: "superscreenshot.selftest.prefs.bg")!
        suite.removePersistentDomain(forName: "superscreenshot.selftest.prefs.bg")
        Defaults.store = suite
        defer { Defaults.store = .standard; suite.removePersistentDomain(forName: "superscreenshot.selftest.prefs.bg") }
        check(WindowBackgroundMapping.style(for: .desktop) == .desktopWallpaper, "desktop")
        check(WindowBackgroundMapping.style(for: .custom) == .customWallpaper, "custom")
        check(WindowBackgroundMapping.style(for: .color) == .color, "color")
        Defaults[.windowBackgroundStyle] = .transparent
        Defaults[.wallpaperSource] = .custom
        WindowBackgroundMapping.syncAfterWallpaperChange()
        check(Defaults[.windowBackgroundStyle] == .transparent, "transparent isn't changed by wallpaper edits")
        WindowBackgroundMapping.applyWallpaper()
        check(Defaults[.windowBackgroundStyle] == .customWallpaper, "with wallpaper follows the source")
        let red = RGBAColor(r: 1, g: 0, b: 0)
        Defaults[.wallpaperColor] = red
        Defaults[.wallpaperSource] = .color
        WindowBackgroundMapping.syncAfterWallpaperChange()
        check(Defaults[.windowBackgroundStyle] == .color && Defaults[.windowBackgroundColor] == red, "plain color copied")
    }))

    SelfTest.cases.append(("Prefs.afterCaptureRule", {
        let one: Set<AfterCaptureAction> = [.save]
        check(AfterCaptureRules.toggling(.save, on: false, in: one) == nil, "removing the last action is refused")
        check(AfterCaptureRules.toggling(.copyToClipboard, on: true, in: one) == [.save, .copyToClipboard], "adding works")
        check(AfterCaptureRules.toggling(.save, on: false, in: [.save, .pin]) == [.pin], "removing a non-last action works")
        check(AfterCaptureRules.toggling(.pin, on: false, in: one) == one, "removing an absent action is a no-op")
        check(!AfterCaptureRules.screenshotChoices.contains(.openVideoEditor), "video editor isn't a screenshot action")
        check(!AfterCaptureRules.recordingChoices.contains(.annotate), "annotate isn't a recording action")
        check(Set(AfterCaptureRules.tableRows) == Set(AfterCaptureRules.screenshotChoices + AfterCaptureRules.recordingChoices)
              && AfterCaptureRules.tableRows.count == Set(AfterCaptureRules.tableRows).count, "table covers every action once")
        check(AfterCaptureRules.title(for: .upload) == "Upload & copy link", "upload row names our destinations")
    }))

    SelfTest.cases.append(("Prefs.shortcutPlanner", {
        let cs: NSEvent.ModifierFlags = [.command, .shift]
        let cmdShift4 = Shortcut(key: kVK_ANSI_4, modifiers: cs)
        // Another action already owns ⇧⌘4; applying system defaults must clear it.
        var stored: [String: Shortcut?] = [AppAction.captureWindow.rawValue: cmdShift4]
        let effective = ShortcutPlanner.effective(stored)
        check(ShortcutPlanner.conflict(for: cmdShift4, excluding: .captureArea, in: effective) == .captureWindow, "conflict detected")
        check(ShortcutPlanner.conflict(for: cmdShift4, excluding: .captureWindow, in: effective) == nil, "own shortcut isn't a conflict")
        check(effective[.captureArea] == AppAction.captureArea.defaultShortcut, "missing entry → default")

        stored = ShortcutPlanner.applying(ShortcutPlanner.systemDefaultAssignments, to: stored)
        let after = ShortcutPlanner.effective(stored)
        check(after[.captureArea] == cmdShift4, "area → ⇧⌘4")
        check(after[.captureFullscreen] == Shortcut(key: kVK_ANSI_3, modifiers: cs), "fullscreen → ⇧⌘3")
        check(after[.allInOne] == Shortcut(key: kVK_ANSI_5, modifiers: cs), "all-in-one → ⇧⌘5")
        check(after[.captureWindow] == nil && stored[AppAction.captureWindow.rawValue] != nil, "colliding action explicitly cleared")
        check(ShortcutPlanner.duplicates(in: after).isEmpty, "no duplicates after applying")
        check(ShortcutPlanner.isApplied(ShortcutPlanner.systemDefaultAssignments, in: stored), "isApplied")
        check(!ShortcutPlanner.isApplied(ShortcutPlanner.systemDefaultAssignments, in: [:]), "defaults aren't system shortcuts")

        let dup: [AppAction: Shortcut] = [.captureArea: cmdShift4, .captureText: cmdShift4]
        check(ShortcutPlanner.duplicates(in: dup)[cmdShift4]?.count == 2, "duplicates found")

        let found = ShortcutPlanner.filter(AppAction.allCases, query: "gif")
        check(found == [.recordGIF], "search by title")
        check(ShortcutPlanner.filter(AppAction.allCases, query: "  ").count == AppAction.allCases.count, "blank query keeps all")
        check(ShortcutPlanner.filter(AppAction.allCases, query: "capture area copy") == [.captureAreaAndCopy], "multi-word search")
        let groups = ShortcutPlanner.grouped(AppAction.allCases)
        check(groups.map(\.group) == ShortcutGroup.allCases, "every group used, in pane order")
        check(groups.first?.actions.first == .allInOne, "General group starts with All-In-One")
        check(groups.map(\.actions.count).reduce(0, +) == AppAction.allCases.count, "grouping covers every action")
        check(ShortcutPlanner.filter(AppAction.allCases, query: "ocr") == [.captureText], "search by group title")
    }))

    SelfTest.cases.append(("Prefs.systemHotkeys", {
        check(SystemScreenshotHotkeys.enabledIDs(in: nil) == Set(SystemScreenshotHotkeys.ids), "missing plist → all enabled")
        let dict: [String: Any] = ["28": ["enabled": false], "29": ["enabled": NSNumber(value: false)],
                                   "30": ["enabled": true], "31": ["enabled": false], "184": ["enabled": false]]
        check(SystemScreenshotHotkeys.enabledIDs(in: dict) == [30], "parses enabled flags")
        let cs: NSEvent.ModifierFlags = [.command, .shift]
        check(SystemScreenshotHotkeys.id(for: Shortcut(key: kVK_ANSI_4, modifiers: cs)) == 30, "⇧⌘4 → 30")
        check(SystemScreenshotHotkeys.id(for: Shortcut(key: kVK_ANSI_3, modifiers: cs.union(.control))) == 29, "⌃⇧⌘3 → 29")
        check(SystemScreenshotHotkeys.id(for: Shortcut(key: kVK_ANSI_4, modifiers: [.option, .shift])) == nil, "⌥⇧4 isn't a system shortcut")
        let eff: [AppAction: Shortcut] = [.captureArea: Shortcut(key: kVK_ANSI_4, modifiers: cs),
                                          .allInOne: Shortcut(key: kVK_ANSI_5, modifiers: cs)]
        check(SystemScreenshotHotkeys.shadowedActions(effective: eff, enabledIDs: [30]) == [.captureArea], "shadowed actions")
    }))

    SelfTest.cases.append(("Prefs.templateEditing", {
        let r = TemplateEditing.inserting("%Y", into: "ab", replacing: NSRange(location: 1, length: 0))
        check(r.text == "a%Yb" && r.caret == 3, "insert at caret")
        let s = TemplateEditing.inserting("%d", into: "abc", replacing: NSRange(location: 1, length: 1))
        check(s.text == "a%dc" && s.caret == 3, "replace selection")
        let c = TemplateEditing.inserting("%i", into: "x", replacing: NSRange(location: 99, length: 5))
        check(c.text == "x%i" && c.caret == 3, "out-of-range selection clamps")
        check(TemplateEditing.unknownTokens(in: "%a %q %Y %% %z %q") == ["%q", "%z"], "unknown tokens")
        check(TemplateEditing.substitutingCounter(in: "n%i %%i", with: 42) == "n42 %%i", "counter substitution keeps escapes")
        check(FileNameTemplate.render(TemplateEditing.substitutingCounter(in: "S %i", with: 7), kind: "x", advanceCounter: false) == "S 7",
              "substituted preview renders")
    }))

    SelfTest.cases.append(("Prefs.headersAndLanguages", {
        let rows = HeaderRow.rows(from: ["b": "2", "A": "1"])
        check(rows.map(\.name) == ["A", "b"], "rows sorted")
        let dict = HeaderRow.dictionary(from: rows + [HeaderRow(name: "  ", value: "x"), HeaderRow(name: " c ", value: "3")])
        check(dict == ["A": "1", "b": "2", "c": "3"], "blank names dropped, names trimmed")

        let available = ["en-US", "fr-FR", "de-DE"]
        check(OCRLanguageSelection.toggling("en-US", on: false, in: ["en-US"], available: available) == ["en-US"],
              "last language can't be removed")
        check(OCRLanguageSelection.toggling("de-DE", on: true, in: ["fr-FR", "en-US"], available: available)
              == ["en-US", "fr-FR", "de-DE"], "recognizer order")
        check(OCRLanguageSelection.toggling("en-US", on: true, in: ["xx-XX"], available: available) == ["en-US", "xx-XX"],
              "unknown stored codes kept after known ones")
        check(OCRLanguageSelection.toggling("xx-XX", on: true, in: ["xx-XX"], available: []) == ["xx-XX"], "no duplicates")
    }))

    SelfTest.cases.append(("Prefs.restoreDefaults", {
        let suite = UserDefaults(suiteName: "superscreenshot.selftest.prefs")!
        suite.removePersistentDomain(forName: "superscreenshot.selftest.prefs")
        Defaults.store = suite
        defer { Defaults.store = .standard }
        check(Set(PreferencesReset.restorableKeys.map(\.name)).count == PreferencesReset.restorableKeys.count, "no duplicate keys")
        check(!PreferencesReset.restorableKeys.contains { $0.name == Defaults.Keys.onboardingCompleted.name }, "onboarding state kept")
        Defaults[.screenshotFormat] = .jpeg
        Defaults[.afterScreenshotActions] = [.pin]
        Defaults[.onboardingCompleted] = true
        AppAction.captureArea.shortcut = nil
        PreferencesReset.restoreAll()
        check(Defaults[.screenshotFormat] == .png, "format restored")
        check(Defaults[.afterScreenshotActions] == [.showQuickAccess], "after-capture restored")
        check(AppAction.captureArea.shortcut == AppAction.captureArea.defaultShortcut, "shortcuts restored")
        check(Defaults[.onboardingCompleted], "onboarding flag untouched")
        suite.removePersistentDomain(forName: "superscreenshot.selftest.prefs")
    }))
}
