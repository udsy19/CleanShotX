# Changelog

All notable changes to Super Screenshot are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org).

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

[1.2.0]: https://github.com/udsy19/super-screenshot/releases/tag/v1.2.0
[1.1.0]: https://github.com/udsy19/super-screenshot/releases/tag/v1.1.0
[1.0.1]: https://github.com/udsy19/super-screenshot/releases/tag/v1.0.1
[1.0.0]: https://github.com/udsy19/super-screenshot/releases/tag/v1.0.0
