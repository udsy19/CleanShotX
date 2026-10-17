# PreferencesKit — reconstructed spec (Settings window + onboarding)

Evidence: `docs/re/raw/classes-digest.md` (class/ivar/selector names), `ui-sentences.txt` / `strings-app.txt`
(UI labels), `nibs.txt` (`NameTemplateWindow.nib`), `defaults-sample.txt` (stored keys on a real install).
Labels quoted below are short UI strings needed for parity; long prose is rewritten.

## 1. Window architecture

| Evidence | Reading |
|---|---|
| `Preferences : NSWindowController` — `windowDidBecomeKey:`, `windowDidResignMain:`, `windowWillClose:`, `showWindow:` | One reusable window controller; reacts to key/main changes (the app flips activation for an accessory app). |
| `PRViewController : NSSplitViewController` — `sidebarWidth`, `menuControl`, `accountView`, `router`, `contentViewController` | CleanShot 5 uses a **System-Settings-style sidebar**, not toolbar tabs. |
| `PRMenuControl : NSView` — `items`, `disabledItemIDs`, `selectedItem`, `iconSize`, `itemHeight` ; `PRMenuControl.Item` (`id`, `image`) | Sidebar rows = (id, icon). Some rows can be disabled. |
| `PRRouter` — `_selection`, `_isActivated`, `navigate` | Observable router; external callers navigate to a pane id (URL scheme `open-settings?tab=`). |
| `PRSidebarAccountModel` (`_user`) | Cloud account header in sidebar — **not reimplemented** (no CleanShot Cloud). |
| `*Settings : _TtCs12_SwiftObject` classes with `_`-prefixed ivars | SwiftUI `ObservableObject` models per pane (property wrappers ⇒ `_x` ivars). Panes are SwiftUI. |

Shotcraft: `PreferencesWindowController` owns one `NSWindow` (titled, closable, miniaturizable, resizable,
`fullSizeContentView`, frame autosave) hosting a SwiftUI `NavigationSplitView`. `show(pane:)` selects the
pane (case-insensitive ids + aliases, e.g. `cloud`→`upload`), calls `NSApp.activate()` and
`makeKeyAndOrderFront`. The last pane is stored in `prefs.lastPane`.

Pane ids: `general, wallpaper, shortcuts, quickAccess, recording, screenshots, annotate, upload, advanced, about`
(mirrors `GeneralSettings, WallpaperSettings, ShortcutsSettings, QuickAccessSettings, ScreenRecordingSettings,
ScreenshotsSettings, AnnotateSettings, CloudSettings, AdvancedSettings, AboutSettings`).

## 2. Panes

### General — `GeneralSettings`
ivars `_screenshotLocation, _startAtLogin, _showMenubarIcon, _hideDesktopIcons, _playSounds, _screenshotSound,
_afterScreenshot, _afterVideo, _copyPriority`.
- Launch at login (`.launchAtLogin`; the app target registers `SMAppService`).
- Play sounds + capture sound picker (`.captureSound`) with a preview button (`Sound.play(.capture)`).
- "Show menu bar icon" — turning it off confirms: "The menu bar icon will be hidden." + "In order to show the
  Settings window again, launch CleanShot twice." (app target's `applicationShouldHandleReopen` already opens Settings).
- Export location (`ScreenLocationPopUpButton` — `chooseLocation`; strings "Choose export location"): popup with
  current folder, "Other…" (NSOpenPanel), "Show in Finder".
- After capture — "Decide what should happen after taking a screenshot or recording a video." Two checkbox lists
  (`_afterScreenshot`, `_afterVideo`). Unchecking the last item is refused with "At least one action needs to be
  enabled" / "Please select at least one thing that should happen after capturing your screen."
  Screenshot actions: Quick Access, copy, save, annotate, upload, pin. Recording actions: Quick Access, copy, save,
  upload, open video editor.
- Clipboard content (`_copyPriority` → `.clipboardContent`).
- "Hide desktop icons while capturing" (`_hideDesktopIcons`, defaults sample `captureWithoutDesktopIcons`).
- Permissions section (Shotcraft addition, required for accessory apps): Screen Recording, Accessibility,
  Microphone, Camera — live status + "Open System Settings" (string present).

### Wallpaper — `WallpaperSettings`
ivars `_overlayType, _plainColor, _customWallpaperName`; `WallpaperLocationPopUpButton.chooseLocation`.
Source (desktop / custom image / plain color), image picker with preview, colour well,
"Update wallpaper when switching Spaces", and a "Hide Desktop Icons"/"Show Desktop Icons" toggle button
(→ `Services.capture.setDesktopIconsHidden`).

### Shortcuts — `ShortcutsSettings`
ivars `_ignoreAfterCapture, _groups, _showsUseSystemDefaults, _showsAfterCaptureBehavior, hotkeyObserver`.
- Grouped list (`_groups` ⇒ `AppAction.group`), "Search shortcuts" field, recorder per action ("Type shortcut",
  "Shortcut is used for another action", "Shortcut is reserved for macOS").
- "Use System Default Shortcuts" (`_showsUseSystemDefaults`) — helper sheet: explains disabling the macOS
  screenshot shortcuts (opens `x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts`), then assigns
  ⇧⌘3 / ⇧⌘4 / ⇧⌘5 to Capture Fullscreen / Capture Area / All-In-One, clearing any other action using them.
- Warning banner "It looks like you haven't disabled Screenshots shortcuts." when an action uses ⇧⌘3/4/5 while
  `com.apple.symbolichotkeys` ids 28/29/30/31/184 are still enabled.
- "Restore Defaults".

### Quick Access — `QuickAccessSettings`
ivars `_positionOnLeft, _moveToActiveDisplay, _overlaySize, _autoClose, _autoCloseMode, _autoCloseInterval,
_closeAfterDragging, _closeAfterUploading, _askForDestinationWhenSaving`; strings "Position on screen",
"Move to active screen", "Close after dragging", "Close after uploading". Overlay size slider with a live preview
card; auto-close (seconds + action on close); save button behaviour; show upload button.

### Recording — `ScreenRecordingSettings`
ivars `_videoFPS, _maxResolution, _downscaleRetina, _showRecordingControls, _displayRecordingTime, _dimScreen,
_rememberRecordingArea, _showCountdown, _doNotDisturb, _showCursor, _highlightClicks, _showKeystrokes,
_recordSystemAudio, _recordAudioInMono, _mergeAudioTracks, _gifFPS, _gifMaxSize, _optimizeGifs, _gifQuality`.
Strings: "Scale Retina videos to 1x", "Dim screen while recording", "Display recording time in menu bar",
"Highlight clicks", "Show Keystrokes", "Record audio in mono", "Enable this option to record sound that comes from
other applications.", "Record microphone", "Record camera", "System Default", "No microphone selected".
Keystrokes need Accessibility → status + request button. Microphone / camera pickers via
`AVCaptureDevice.DiscoverySession` (defaults sample stores `microphoneDeviceID = "<uid>:input"`, i.e. uniqueID).

### Screenshots — `ScreenshotsSettings` + `AdvancedSettings`(naming part)
ivars `_format, _downscaleRetina, _convertTosRGB, _addFrame, _selfTimerInterval, _showCursor, _freezeScreen,
_crosshairMode, _showMagnifier, _backgroundPresetID`. Strings: "Scale Retina screenshots to 1x",
"Convert to sRGB profile", "Add 1px border to all screenshots", "Show cursor on screenshots",
"Freeze screen when taking a screenshot", "Remember last selection",
"To enable magnifier, you must enable Crosshair Mode first." (magnifier disabled until crosshair is on).
Window screenshots: shadow, background (Transparent / Desktop wallpaper / Custom wallpaper / colour), padding.
File naming: "File name format" opens the **NameTemplateWindow** sheet (`NameTemplateViewController`: `tokenField`,
`previewLabel`, `nextNumberTextField`, `restoreDefaultsClicked:`, `okClicked:`, `cancelClicked:`;
`TokenFieldPatternControl` = draggable token chips with `token`/`name`). Shotcraft: text field + clickable token chips
(`FileNameTemplate.tokens`), live preview via `FileNameTemplate.render(advanceCounter: false)`, next counter value,
Restore Defaults / Cancel / OK. "Ask for name after every capture".

### Annotate — `AnnotateSettings`
ivars `_inverseArrowDirection, _smoothDrawing, _rememberBackgroundToolState, _drawShadow, _autoExpandCanvas,
_showColorNames, _alwaysOnTop, _showDockIcon` ⇒ every `.annotate*` key, plus save-button behaviour and crop snapping.

### Upload — `CloudSettings` (replaced)
CleanShot Cloud (`_user, _copyLinkBeforeUpload, _optimizeScreenshots …`) is proprietary. Shotcraft exposes its own
destinations: none / S3-compatible / custom HTTP / synced folder; "Copy link when upload starts"
(`_copyLinkBeforeUpload`); max image width (`_optimizeScreenshots` analogue). S3 secret lives in the Keychain
(`Keychain.s3SecretKeyAccount`). "Test Connection" → `Services.upload.testConnection`; "Recent uploads" list.

### Advanced — `AdvancedSettings`
ivars `_automaticallyDetectLanguage, _primaryLanguage, _keepLineBreaks, _detectLinks, _historyCapacity,
_allowURLSchemes, languages, …`. Strings: "Automatically Detect Language", "Keep line breaks", "Never open links",
"Clear History...", "Are you sure you want to delete all files from history?", "Capture History is disabled.",
"Lock and hide screenshot on mouse over", "Allow URL scheme API", "Reset All Warning Dialogs",
"All warning dialogs are now enabled.", "Restore Defaults".

### About — `AboutSettings` (`_automaticallyCheckForUpdates, _analyticsAllowed`), `Acknowledgments`, `EULA`
Icon, name, version, description, credits. No updater / analytics / EULA (not applicable to a local build).

## 3. Onboarding — `Onboarding : NSWindowController`
ivars `slides, currentView, completionHandler, showReadyToUsePopupAfter`; every slide is an `ONView`
(`primaryButton`, `secondaryButton`, `bottomBar`); `ONBasicView` = image + title + description.

| CleanShot slide | Evidence string | Shotcraft step |
|---|---|---|
| `ONWelcomeView` | "Welcome to CleanShot X", "Let's walk you through a quick configuration" | Welcome |
| (permission alert) | "In order to continue working properly, CleanShot needs Screen Recording permission." | Screen Recording (live status, request / open settings) |
| `ONSystemShortcutsView`, `ONAllInOneShortcutSingle`, `ONDefaultToolView` | "Set as default screenshot tool?", "Use the same shortcut as macOS?", "Do you want to assign system default shortcut to All-In-One mode?", "Use old shortcut" | Shortcuts: macOS ⇧⌘3/4/5, All-In-One on ⇧⌘5 only, or keep ⌥⇧ defaults |
| `ONHideDesktopIconsView : ONSwitchView` | "Would you like to have your desktop icons hidden" | Desktop icons switch |
| `ONLaunchAtLoginView` | "Would you like to have CleanShot ready" | Launch at login |
| `ONPreferencesView` | "You can adjust all the settings and set your own" | After-capture defaults (Quick Access / copy / save) |
| `ONFinishView` (`menubarImageView`) | "CleanShot is ready to use!" | Finish — shows the menu bar icon location |
| `ONStatisticsView`, `ONCloudView` | "Share usage statistics?" | Omitted (no analytics / cloud). |

Closing the window at any step marks `onboardingCompleted = true`.

## 4. Migrators
`HotkeyMigrator`, `DefaultsMigrator` (defaults sample `MGR001…MGR006`) migrate older CleanShot formats; Shotcraft has
no legacy data so nothing is implemented.
