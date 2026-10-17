# Architecture

Super Screenshot is a native macOS menu-bar app written in Swift 6 (Swift 5 language mode), built with SwiftPM and Apple
frameworks only — no third-party dependencies and no Xcode project. Deployment target: macOS 14.

## Layout

```
Package.swift
Sources/
  SuperScreenshotCore/     shared contracts & utilities: typed Defaults + settings keys, AppAction, shortcuts & global hotkeys,
                           CapturedMedia, the Services registry, MediaPipeline (after-capture flow), Clipboard, ImageTools,
                           ScreenCapturer (ScreenCaptureKit stills), CaptureExclusion, WindowInfo, ScreenGeometry,
                           Sound, Permissions, Alerts, HUD, DockIcon, Keychain
  CaptureKit/              selection overlay, area / window / fullscreen / previous / self-timer / All-In-One captures,
                           freeze screen, crosshair & magnifier, colour picker, desktop-icon hiding, window backgrounds
  AnnotateKit/             Annotate editor and `.superscreenshot` documents
  RecordingKit/            video & GIF recording, recording overlays (clicks, keystrokes, camera), video editor
  StudioKit/               Studio Mode: cursor-tracked recording, timeline editor, compositor and export
  OverlayKit/              Quick Access overlay, pinned screenshots, Capture History
  TextKit/                 text recognition (OCR) and scrolling capture
  PreferencesKit/          Settings window and onboarding
  UploadKit/               uploads to S3-compatible storage, a custom HTTP endpoint or a synced folder
  SuperScreenshot/         app target: AppDelegate, menu bar, ActionRouter, URL scheme, hotkeys, main menu
  SuperScreenshotSelfTest/ headless logic tests (`swift run SuperScreenshotSelfTest`)
Extensions/                share-menu and Quick Look extensions (built with swiftc by scripts/build-extensions.sh)
Tools/e2e/                 UI driver and helpers for the end-to-end suite
scripts/                   build, sign, package, install and test scripts
website/                   the project website (GitHub Pages)
docs/specs/                per-feature specifications and UI reference
```

## How the pieces talk

Feature modules depend only on `SuperScreenshotCore` and never import each other. Each module exposes
`<Module>Module.install()`, which registers its implementations in the `Services` registry
(`Services.capture`, `Services.annotate`, `Services.quickAccess`, …). Cross-module calls always go through that
registry, so any module can be rebuilt, tested or replaced on its own.

```
hotkey / menu bar / URL scheme
        │
        ▼
ActionRouter.perform(AppAction) ──► Services.<module>
        │
        ▼  capture produces a CGImage (or a recording file)
MediaPipeline.didCaptureImage / didFinishRecording
   post-process (Retina → 1x, sRGB, border) → write file → history → sound
        │
        ▼  after-capture actions from Settings
Quick Access overlay · copy · save · annotate · upload · pin · video editor
```

## Conventions

- **After a capture**, hand the result to `MediaPipeline`; modules never implement save/copy/quick-access themselves.
- **Settings** use typed keys in `SuperScreenshotCore/Settings.swift` (`Defaults[.key]`, SwiftUI `@Default(.key)`).
  Module-private state declares extra keys inside the module, prefixed with the module name.
- **Coordinates**: public APIs use global Cocoa coordinates (bottom-left origin); convert with `ScreenGeometry`
  for CoreGraphics / ScreenCaptureKit (top-left origin).
- **Capture exclusion**: Super Screenshot windows above the floating level (overlays, cards, HUDs) never appear in captures;
  pins and editors do, like any other window. Flag special cases with `CaptureExclusion.exclude(_:)`.
- **Concurrency**: UI code is `@MainActor`; heavy work (Vision, encoding, stitching) runs off the main thread.
- **Local first**: nothing leaves the Mac except uploads to a destination the user configured. No analytics.
- **Look & feel**: native materials, SF Symbols, system sounds, full dark-mode support, keyboard shortcuts.
- **No dead code**: remove superseded code in the same change.

## Building

```sh
swift build                         # everything (debug)
swift build --target AnnotateKit    # one module
swift run SuperScreenshotSelfTest   # logic tests
./scripts/build-app.sh [--debug]    # signed app bundle in build/
./scripts/e2e.sh                    # end-to-end suite against the running app
./scripts/make-dmg.sh               # universal DMG in dist/
```
