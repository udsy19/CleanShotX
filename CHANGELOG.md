# Changelog

All notable changes to Super Screenshot are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- Crash-safe recordings: videos, GIFs and Studio recordings are written with movie fragments into an in-progress
  folder, so a crash, force quit, power loss or a stop by the system keeps everything up to the last two seconds.
  The next launch recovers it as "<name> (recovered)" and shows it like any other recording. A writer that fails
  mid-recording (disk full, display unplugged) keeps the part already on disk instead of deleting it.
- Annotate keeps a recovery copy of unsaved edits (one second after every change); after a crash the next launch
  offers to reopen them. Quitting with unsaved edits asks to save first.
- Uploads retry transient network errors with backoff, say so when credentials are rejected, offer "Try Again",
  and clear a pre-copied link that turned out dead.

### Fixed
- ⌘Q (and the on-quit update install) no longer truncates a running recording: the app stops it and waits for
  the file before exiting.
- A failed GIF conversion keeps the recording as a video; cancelling a video export while it starts no longer
  crashes; exports write to a temporary file and never delete a folder given as the destination.
- Studio GIF exports stream frames instead of holding them all in memory; S3 multipart uploads read to the end of
  a file that grew while uploading.

## [1.3.1] — 2026-10-18

### Changed
- Maintenance release; the first update delivered through automatic background updates.

## [1.3.0] — 2026-10-17

### Added
- Automatic updates: Super Screenshot checks GitHub Releases a minute after launch and every 6 hours, downloads a
  newer version in the background, verifies its SHA-256 and code signature, and installs it when you quit — or,
  after 10 minutes of inactivity with no windows open, swaps it in and relaunches quietly. "Updated to x.y.z"
  appears the next time you open the menu. Turn it off in Settings → General → Install updates automatically;
  Settings → About shows when it last checked.

## [1.2.0] — 2026-10-17

### Changed
- Renamed to Super Screenshot (bundle id `com.udsy.superscreenshot`, URL scheme `superscreenshot://`). Settings and
  captures move over automatically; macOS asks for Screen Recording permission again because the app identity changed.
- Annotate projects are saved as `.superscreenshot` and Studio projects as `.superscreenshotvideo`; projects saved
  under the old name still open. The one-line installer replaces the copy installed under the old name.
- Redesigned website: every figure is a coded close-up of the app instead of a device screenshot.

## [1.1.0] — 2026-10-17

### Changed
- Quick Access cards match CleanShot X: 210 × 150 pt at the default size, 40 pt from the screen edge and above the
  Dock, 10 pt apart, with 17 pt corners on macOS 26.
- Cards spring in from the screen edge and slide back out when closed; cards above settle into the gap.
- Hover controls: centred Copy and Save pills and four frosted corner buttons that scale with the overlay size.
- Settings → Quick Access → Overlay size is a five-step slider.
- The capture overlay shows the real desktop wallpaper and fades in and out.
- The menu bar menu lists the same items as CleanShot X, opens without a scroll arrow and uses slightly larger
  text and rows; the menu bar glyph matches the app icon.

### Removed
- The capture fly-in animation (cards slide in instead).

## [1.0.1] — 2026-10-17

### Changed
- New app icon: ink viewfinder with a red capture dot on warm paper.
- Onboarding adds a "Private by design" step explaining that Shotcraft is a local app and why macOS asks before
  the first launch of a downloaded copy.
- Settings switches expose their labels to VoiceOver.

## [1.0.0] — 2026-10-16

First public release.

### Added
- Screenshots: area, previous area, fullscreen, window (with wallpaper/colour backgrounds), self-timer, All-In-One,
  freeze screen, crosshair & magnifier, colour picker, hide desktop icons.
- Quick Access overlay with copy, save, annotate, pin, upload and drag-and-drop.
- Annotate editor: crop, shapes, five arrow styles, text styles, pen, highlighter, pixelate/blur, spotlight, counters,
  images and a background tool; editable `.shotcraft` documents.
- Screen recording to video or GIF with microphone, system audio, camera, click highlights and keystrokes;
  video editor with trimming and export.
- Studio Mode: cursor-tracked recordings with automatic zoom, smooth cursor, backgrounds and a timeline editor.
- Text recognition (OCR), scrolling capture, pinned screenshots and Capture History.
- Uploads to S3-compatible storage, a custom HTTP endpoint or a synced folder.
- Global shortcuts for every action, a `shotcraft://` URL scheme, share-menu and Quick Look extensions.
- One-line installer and a universal (Apple silicon + Intel) DMG.

[1.3.0]: https://github.com/udsy19/super-screenshot/releases/tag/v1.3.0
[1.2.0]: https://github.com/udsy19/super-screenshot/releases/tag/v1.2.0
[1.1.0]: https://github.com/udsy19/super-screenshot/releases/tag/v1.1.0
[1.0.1]: https://github.com/udsy19/super-screenshot/releases/tag/v1.0.1
[1.0.0]: https://github.com/udsy19/super-screenshot/releases/tag/v1.0.0
