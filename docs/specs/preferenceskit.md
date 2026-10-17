# PreferencesKit — reconstructed spec (Settings window + onboarding)

Evidence: the app's class metadata (class/ivar/selector names), UI strings / app strings
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

Shotcraft (5.0 layout, `docs/specs/ui-reference.md` §13): `PreferencesController` owns one `NSWindow` (titled, closable,
miniaturizable, resizable, `fullSizeContentView`, frame autosave) hosting a SwiftUI `NavigationSplitView`. The window is
810×660 pt, fixed width, resizable vertically (min height 480); a restored frame of another width or off-screen is
normalised. `hosting.sizingOptions = [.minSize]` so switching panes never resizes or collapses the window.
`show(pane:)` selects the pane (case-insensitive ids + aliases, e.g. `cloud`→`upload`), deminiaturizes, activates and
orders front. The last pane is stored in `prefs.lastPane`.

Sidebar (`PRMenuControl`): 220 pt floating inset column; a header (app icon, "Shotcraft", upload destination — the
stand-in for the Cloud account header, click → Upload pane); rows with 24 pt colour tiles + white SF Symbols at a
40 pt pitch, grey selection pill (accent-tinted while the sidebar has keyboard focus, ↑/↓ move); About pinned at the
bottom. Pane titles show in the toolbar. In-pane links use `settings://<pane>` URLs.

Pane ids, in sidebar order: `general, shortcuts, quickAccess, wallpaper, screenshots, recording ("Screen Recording"),
annotate, upload, advanced`, then `about`.

Keyboard: the app target installs a main menu with Edit/File items at launch, so ⌘X/C/V/A/Z/⇧⌘Z/⌘W work in Settings,
its sheets and onboarding without module-level routing.

## 2. Panes (as built)

| Pane | Sections → controls |
|---|---|
| General | App (Launch at login, Show menu bar icon — confirm before hiding); Capture (Hide desktop icons + link to Wallpaper); Sounds (Play sounds, Shutter sound popup + preview); Export (Export location, Choose…, reveal); **After Capture** table Action \| Screenshot \| Recording with checkboxes and "—" where N/A (refuses an empty set); Permissions (live status, refreshed on app activation + polling). |
| Shortcuts | Toolbar "Search shortcuts"; System-shortcut banner/helper; groups with glyph headers (`ShortcutGroup`: General, Screenshots, Screen Recording, Scrolling Capture, OCR, Quick Access Overlay & Pins, Annotate); 156×28 recorders; duplicate / reserved-by-macOS badges; Restore Defaults. |
| Quick Access | Appearance (Position popup, Move to active screen, Overlay size slider with 5 ticks); Behavior (Auto-close, Action, Interval — disabled until auto-close); Close after dragging / uploading, Show upload button, Save button behavior. |
| Wallpaper | Desktop (preview, Wallpaper popup: desktop / custom image / plain color, Update when switching Spaces or image chooser or colour well); Desktop icons Hide/Show button (state re-read on activation and every second). Changing the wallpaper keeps a "With wallpaper" window background in step. |
| Screenshots | Output (File format popup, Quality for JPG/HEIC); sRGB / Retina 1x / 1px border box; Capture (Self-Timer interval, Show cursor, Freeze screen); Window Screenshots (two tiles "With wallpaper" / "Transparent", Padding, Capture window shadow, Reset Defaults); Crosshair (Crosshair Mode popup, Show magnifier). |
| Screen Recording | General (controls, remember selection, menu-bar time, dim, countdown + seconds, Do Not Disturb, Studio Mode default); Cursor (show, hide when idle, Highlight clicks + Options… popover colour); Keystrokes (+ Accessibility status); Video (format, fps, quality, Retina 1x); Audio (mono, microphone + device, system audio); Camera; GIF (fps, "800 × auto" resolution). |
| Annotate | Tools (inverse arrow, smooth drawing, remember background tool, shadow, auto-expand canvas, crop snapping); Window (always on top, Dock icon, save button); Accessibility (colour names). |
| Upload (replaces Cloud) | Header box (destination tile, summary, Test Connection + result) and Destination popup; per-destination fields with inline URL validation; Upload (screenshot size); Clipboard (copy link when upload starts); Recently Uploaded (refreshed on activation). S3 secret in the Keychain. |
| Advanced | File Name (ask for name, File name format Customize… sheet); Clipboard (copy format); Capture History (Keep history popup incl. Disabled/Forever, Clear History…); Text Recognition (Language popup from `Services.text.supportedLanguages()` + Choose… multi-select sheet, keep line breaks, detect links); All-In-One (remember last selection); Pinned Screenshots; API (URL scheme toggle + command reference); Reset (warning dialogs, restore all defaults). |
| About | Icon, version, credits, data folder, Show Onboarding…. |

File-name sheet (`NameTemplateWindow`): instruction line, template field, live "Preview:" (+ recording), two-column
legend of light-blue token chips (click inserts at the caret), "Auto-increment next number:" (validated as a
non-negative integer; OK disabled otherwise), Restore Defaults / Cancel / OK.

Not built (no backing setting or feature yet): Screenshots "Background preset", "Add @2x suffix", GIF "Optimize" and
"Quality", Audio "tracks", keystroke Options…, Upload "Notifications", PixelSnap promo.

## 3. Onboarding — `Onboarding : NSWindowController`
ivars `slides, currentView, completionHandler, showReadyToUsePopupAfter`; every slide is an `ONView`
(`primaryButton`, `secondaryButton`, `bottomBar`); `ONBasicView` = image + title + description.

Shotcraft: fixed 580×560 window (transparent title bar, safe area ignored so the bottom bar stays inside), slides
slide horizontally; each slide = 100 pt illustration, 22 pt bold title, 13 pt secondary body, accessory; bottom bar
with Back, page dots, secondary and a prominent primary (Return).

| CleanShot slide | Shotcraft step and visual |
|---|---|
| `ONWelcomeView` | Welcome — app icon (`NSApp.applicationIconImage`) + 2×3 feature summary tiles |
| (permission alert) | Screen Recording — live status, Grant Access… / Open System Settings |
| `ONSystemShortcutsView`, `ONDefaultToolView` | "Set as default screenshot tool?" — keycap illustration, three choices, warning if the macOS shortcuts are still on |
| `ONHideDesktopIconsView` | Desktop icons — mini desktop whose icons fade with the switch |
| `ONLaunchAtLoginView` | Launch at login — menu bar illustration |
| `ONPreferencesView` | "Tweak your workflow" — after-capture checkboxes |
| `ONFinishView` | "Shotcraft is ready to use!" — app icon, menu bar arrow, the user's effective shortcuts |
| `ONStatisticsView`, `ONCloudView` | Omitted (no analytics / cloud account). |

Closing the window at any step marks `onboardingCompleted = true`.

## 4. Migrators
`HotkeyMigrator`, `DefaultsMigrator` (defaults sample `MGR001…MGR006`) migrate older CleanShot formats; Shotcraft has
no legacy data so nothing is implemented.
