# Testing

Super Screenshot is built with the Command Line Tools only (no Xcode), so XCTest/Swift Testing aren't available.
Testing has three layers.

## 1. Self-tests — `swift run SuperScreenshotSelfTest`

83 headless test groups covering the pure logic of every module, e.g.:

| Area | What's checked |
|---|---|
| Core | file-name templates, typed defaults round-trips, shortcut uniqueness, coordinate conversion |
| CaptureKit | drag/resize/nudge math, edge snapping, handles, pixel cropping, aspect ratios, toolbar layout |
| AnnotateKit | geometry & hit testing, arrow generation, smoothing, undo stack, export pixel size, `.superscreenshot` round-trip |
| RecordingKit | timer formatting, even pixel sizes, bitrate/size estimates, GIF frame timing, pause clock |
| StudioKit | clip timeline cut/split, zoom planning & easing, smart zoom, cursor smoothing, project JSON, export estimates |
| OverlayKit | card sizing & stack layout, pin geometry, history persistence/pruning/filters |
| TextKit | OCR text assembly & line joining, scrolling-capture stitching (vertical/horizontal, pixel-exact), offset detection |
| PreferencesKit | pane routing, after-capture validation, shortcut planner, template editing, restore defaults |
| UploadKit | AWS SigV4 against AWS-published vectors, S3 URLs/XML, multipart bodies, JSON link extraction |

## 2. End-to-end suite — `scripts/e2e.sh`

Drives a running `build/SuperScreenshot.app` with synthetic mouse/keyboard input through the Accessibility API
(`Tools/e2e/ui.swift`) and checks real outputs. Every capture targets a pinned synthetic test card, so no other
screen content is involved; preferences are backed up and restored, and only files created by the run are removed.

| Check | Verified by |
|---|---|
| URL `capture-area` | captured pixels match the test card colour |
| Capture & copy | clipboard holds a PNG of the expected pixel size |
| Interactive area selection | drag on the overlay → capture with expected pixels |
| Window capture | click on a window → capture at the window's full pixel size |
| Capture Text (OCR) | clipboard contains the test card's text |
| Video recording | MP4 decodes at the expected size/duration |
| GIF recording | GIF at expected size with animation frames |
| Upload (synced folder) | file copied, percent-encoded link on the clipboard |
| Save to export location | file written to the export folder |
| Desktop icons hide/show | desktop-level cover windows appear/disappear |
| Settings window | opens on the requested pane |

Requirements: the terminal running it has Accessibility permission and Super Screenshot has Screen Recording permission.
The script takes over the mouse for ~2 minutes.

## 3. Manual end-to-end verification (release 1.0.0)

Exercised on macOS 26.5 (Apple silicon) with the Accessibility driver and window-only screenshots:

- Onboarding window; Settings: all 10 panes render, toggles persist, Test Connection, recent uploads.
- Capture: area (URL + interactive), previous area, fullscreen path, window (incl. pins), self-timer countdown,
  All-In-One toolbar capture, freeze screen, global hotkey → overlay → Esc cancel, colour picker (`#4D80F2`).
- Quick Access cards: hover controls, Copy, Save, Upload (closes after upload), Annotate, Restore from history.
- Annotate: opens full size from a card; rectangle, counter, arrow, pixelate, text tool typing; Done writes the
  edited image back; unsaved-changes prompt.
- Recording: setup panel → countdown → MP4; GIF; video editor (timeline thumbnails, audio panel, export).
- Studio Mode: setup → recording with click/cursor events → project package → editor preview & playback →
  export sheet → MP4 with background, padding, shadow and custom cursor.
- OCR repeated 3× reliably; scrolling capture of a long pane stitched without seams.
- Capture History: filters, durations/GIF badges, Restore.
- Quick Look: `.superscreenshot` thumbnail and preview, `.superscreenshotvideo` thumbnail (via `qlmanage -x`).
- DMG: mounts, contains app + Applications link + install notes; app and all 4 extensions are universal
  (arm64 + x86_64) and pass `codesign --verify --deep --strict`.

### Bugs found and fixed during E2E

- Annotate/Studio editor windows collapsed to toolbar height (vertical `NSBox` separator hugging).
- Selection overlay let clicks fall through to the window underneath (transparent-pixel click-through).
- Captures excluded pinned screenshots and editor windows; window selection skipped them.
- Studio preview/export showed an empty first frame (leading empty edit in the screen recording).
- Recording panel truncated "Record in Studio Mode"; Studio colour well overlapped the swatch grid.
- Settings switches had no accessibility labels.

### Not automatable here

- Share-menu extensions ("Annotate with Super Screenshot", "Pin to the Screen") are built, signed and registered
  (`pluginkit -m`); invoking them requires a Finder/Photos share menu click.
- Gatekeeper: the DMG is self-signed, not notarized — `spctl` rejects it as expected; first launch needs
  System Settings → Privacy & Security → Open Anyway (documented in the DMG).
