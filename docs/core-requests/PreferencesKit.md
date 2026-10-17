# Core requests from PreferencesKit

## 1. Done
- `FileNameTemplate.counterKey` is public; PreferencesKit uses it directly.
- `Services.text.supportedLanguages()` feeds the OCR language list (empty list if TextKit isn't installed).

## 2. Semantics the owning modules should follow (no new keys)
These are existing Core keys; this is the meaning the Settings UI shows, so the owning modules should behave the same way:

| Key | UI label / meaning | Owner |
|---|---|---|
| `quickAccessAutoCloseAction` | `nil` = "Just close"; `.save` / `.copyToClipboard` / `.upload` run on auto-close | OverlayKit |
| `quickAccessSize` | slider 0.6…1.4, step 0.1, shown as a percentage | OverlayKit |
| `ocrOpenLinks` | "Open detected links": when the recognised text is a single link, open it | TextKit |
| `ocrLanguageMode` / `ocrLanguages` | Manual mode uses `ocrLanguages` in order; list is never empty; codes come from `Services.text.supportedLanguages()` | TextKit |
| `historyRetentionDays` / `historyEnabled` | "Keep history" popup: Disabled (`historyEnabled = false`), 1/3/7/14/30/90 days, `0` = forever | OverlayKit |
| `windowBackgroundStyle` | Two tiles: "Transparent", or "With wallpaper" = the style matching `wallpaperSource` (desktop → `.desktopWallpaper`, custom → `.customWallpaper`, color → `.color` with `windowBackgroundColor` = `wallpaperColor`); kept in step when the Wallpaper pane changes | CaptureKit |
| `uploadMaxImageWidth` | `0` = original size | UploadKit |
| `customHTTPResponseURLPath` | dot-separated JSON path; empty = the response body is the link | UploadKit |
| `gifMaxWidth` | `0` = original | RecordingKit |
| `selfTimerSeconds` | 3 / 5 / 10 | CaptureKit |
| `rememberLastSelection` | shown under Advanced → All-In-One (that is the only place CaptureKit reads it) | CaptureKit |
| `windowBackgroundStyle == .customWallpaper` | uses `customWallpaperPath` from the Wallpaper pane | CaptureKit |
| `recordDoNotDisturb` | "Turn on Do Not Disturb while recording" | RecordingKit |

## 3. Module-private keys (no action needed)
- `prefs.lastPane` — last selected Settings pane.
- Alert suppression id `prefs.hideMenuBarIcon` (stored in `.suppressedWarnings`, cleared by "Reset All Warning Dialogs").

## 4. Notes for the app target
- "Restore Defaults" (Advanced) resets every user-facing key, including `.launchAtLogin` and `.shortcuts`, through
  `Defaults.changes`. The app's existing `Defaults.publisher(.launchAtLogin)` and `.shortcuts` observers pick this up;
  nothing else is needed.
- Settings, its sheets and onboarding rely on the app's main menu (installed at launch) for ⌘X/C/V/A/Z/⇧⌘Z/⌘W.

## 5. Behaviour gaps in other modules (CleanShot parity, not blocking)
- OverlayKit: CleanShot's "Hold ⌥ to keep the item on the overlay after dragging" and "Press Save with ⌥ to choose the
  destination" aren't implemented, so the Quick Access pane doesn't promise them.
- AnnotateKit: "Press ⌥ while drawing to invert the arrow" isn't implemented; the pane describes the setting only.
