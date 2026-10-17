# Shotcraft — architecture & contributor contract

Shotcraft is a from-scratch reimplementation of the CleanShot X 5.0.1 feature set for macOS 14+,
built only with Apple frameworks (no third-party packages) using SwiftPM and the Command Line Tools
(no Xcode). Reverse-engineering evidence lives in `docs/re/` (raw extracts in `docs/re/raw/`).

## Layout

```
Package.swift
Sources/
  ShotcraftCore/     shared contracts & utilities (Defaults, Settings keys, AppAction, Shortcut/Hotkeys,
                     CapturedMedia, Services registry, MediaPipeline, Clipboard, ImageTools,
                     ScreenCapturer (SCK stills), WindowInfo, ScreenGeometry, Sound, Permissions, Alerts, HUD)
  CaptureKit/        selection overlay, area/window/fullscreen/previous/self-timer/All-In-One, freeze screen,
                     crosshair+magnifier, color picker, desktop-icon hiding, window backgrounds
  AnnotateKit/       Annotate editor window + .shotcraft documents
  RecordingKit/      video/GIF screen recording, recording controls & overlays, video editor/trimmer
  StudioKit/         Studio Mode: cursor-tracked recording + timeline editor (auto-zoom, backgrounds, export)
  OverlayKit/        Quick Access Overlay, pinned screenshots, Capture History
  TextKit/           OCR (Capture Text) + Scrolling Capture
  PreferencesKit/    Settings window (all panes) + onboarding
  UploadKit/         upload destinations (S3-compatible, custom HTTP, synced folder)
  Shotcraft/         app target: AppDelegate, status menu, ActionRouter, URL scheme, hotkeys
  ShotcraftSelfTest/ headless logic checks (`swift run ShotcraftSelfTest`)
scripts/build-app.sh  → build/Shotcraft.app (signed with the project-local identity)
```

## Rules for module work

1. **Ownership.** A module touches only `Sources/<Module>/**`, its `Sources/ShotcraftSelfTest/<Module>Tests.swift`,
   and its spec `docs/re/<module>.md`. Never edit `ShotcraftCore`, other modules, `Package.swift` or the app target.
   If you need something from Core, implement it privately inside your module; if it is genuinely
   cross-cutting, also describe it in `docs/core-requests/<Module>.md` for the integrator.
2. **Cross-module calls go through `Services`** (`Services.annotate.open(media)`, `Services.capture.selectArea(...)`, …).
   Modules never import each other. Your `<Module>Module.install()` must assign your service implementations.
3. **After a capture**, hand results to `MediaPipeline.didCaptureImage(...)` / `didFinishRecording(...)`; never
   implement save/copy/quick-access logic yourself.
4. **Settings**: use the keys in `ShotcraftCore/Settings.swift` (`Defaults[.key]`, SwiftUI `@Default(.key)`).
   Module-private state may declare extra keys in your module: `extension Defaults.Keys { static let x = Key<Int>("annotate.x", default: 0) }` —
   prefix the name with your module.
5. **Coordinates**: global Cocoa coordinates (bottom-left origin) everywhere in public APIs. Use `ScreenGeometry`
   to convert to CG/SCK (top-left) coordinates.
6. **Build only your target, in your own scratch dir** (avoids lock contention with parallel work):
   `swift build --target <Module> --scratch-path .build-<module>`. Do not build the whole product or the app bundle.
   Self-tests: `swift build --product ShotcraftSelfTest --scratch-path .build-<module>` may fail due to other
   in-progress modules; that's fine — make sure *your* test file compiles with your target.
7. **Language mode**: Swift 5 mode (tools 5.10). Deployment target macOS 14; newer APIs behind `#available`.
   Main-thread UI code is `@MainActor`.
8. **Originality**: do not copy CleanShot X code, images, sounds, or text verbatim beyond short UI labels needed
   for feature parity. Use SF Symbols and system sounds (`Sound.play`).
9. **Quality bar**: native macOS look (NSVisualEffectView materials, SF Symbols, proper dark mode), keyboard
   shortcuts, no placeholder UI, no `TODO` stubs left behind for features in scope. Delete dead code.

## Runtime flow

`hotkey / menu / URL` → `ActionRouter.perform(AppAction)` → `Services.<module>` → capture produces a `CGImage` →
`MediaPipeline.didCaptureImage` (post-process, write file, history, sound) → after-capture actions
(`Services.quickAccess.show`, `Clipboard.copy`, `Services.annotate.open`, `Services.upload.upload`, `Services.pin.pin`).
