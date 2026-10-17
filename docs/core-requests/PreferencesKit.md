# Core requests from PreferencesKit

## 1. Expose the file-name counter key (small, recommended)
`FileNameTemplate.counterKey` (`"fileNameCounter"`) is `private` in `ShotcraftCore/Files.swift`. The file-name
template sheet lets the user set the next `%i` value (CleanShot's `NameTemplateViewController.nextNumberTextField`), so
PreferencesKit declares its own `Defaults.Key<Int>("fileNameCounter", default: 1)` (`prefsFileNameCounter` in
`PreferencesLogic.swift`) that points at the same storage.
**Request:** make it `public static let counterKey` (or add `public static var nextCounter: Int { get set }`), then
PreferencesKit can drop its duplicate declaration.

## 2. Semantics the owning modules should follow (no new keys)
These are existing Core keys; this is the meaning the Settings UI shows, so the owning modules should behave the same way:

| Key | UI label / meaning | Owner |
|---|---|---|
| `quickAccessAutoCloseAction` | `nil` = "Just close"; `.save` / `.copyToClipboard` / `.upload` run on auto-close | OverlayKit |
| `quickAccessSize` | slider 0.6…1.4, step 0.1, shown as a percentage | OverlayKit |
| `ocrOpenLinks` | "Open detected links": when the recognised text is a single link, open it | TextKit |
| `ocrLanguageMode` / `ocrLanguages` | Manual mode uses `ocrLanguages` in order; list is never empty; codes come from Vision's supported set (`vi-VT` as Vision spells it) | TextKit |
| `historyRetentionDays` | choices 1/3/7/14/30/90, `0` = forever | OverlayKit |
| `uploadMaxImageWidth` | `0` = original size | UploadKit |
| `customHTTPResponseURLPath` | dot-separated JSON path; empty = the response body is the link | UploadKit |
| `gifMaxWidth` | `0` = original | RecordingKit |
| `selfTimerSeconds` | 3 / 5 / 10 | CaptureKit |
| `windowBackgroundStyle == .customWallpaper` | uses `customWallpaperPath` from the Wallpaper pane | CaptureKit |
| `recordDoNotDisturb` | "Turn on Do Not Disturb while recording" | RecordingKit |

## 3. Module-private keys (no action needed)
- `prefs.lastPane` — last selected Settings pane.
- Alert suppression id `prefs.hideMenuBarIcon` (stored in `.suppressedWarnings`, cleared by "Reset All Warning Dialogs").

## 4. Notes for the app target
- "Restore Defaults" (Advanced) resets every user-facing key, including `.launchAtLogin` and `.shortcuts`, through
  `Defaults.changes`. The app's existing `Defaults.publisher(.launchAtLogin)` and `.shortcuts` observers pick this up;
  nothing else is needed.
- The Settings and onboarding windows handle ⌘X/C/V/A/Z/⇧⌘Z/⌘W themselves (`SettingsWindow`), because the accessory app
  has no Edit menu. If the app target later installs a main menu with an Edit menu, that keeps working.
