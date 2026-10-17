# Changelog

All notable changes to Shotcraft are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org).

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

[1.0.1]: https://github.com/udsy19/CleanShotX/releases/tag/v1.0.1
[1.0.0]: https://github.com/udsy19/CleanShotX/releases/tag/v1.0.0
