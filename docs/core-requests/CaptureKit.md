# CaptureKit → Core requests

1. **ScreenCapturer: keep selected own windows.** `ScreenCapturer.capture(rect:on:)` / `capture(globalRect:)`
   exclude the whole app, which also removes our desktop-icon cover windows ("Hide desktop icons while
   capturing"). CaptureKit works around this privately in `Sources/CaptureKit/CaptureEngine.swift` using
   `SCContentFilter(display:excludingApplications:exceptingWindows:)`. Suggested Core API:
   `capture(rect:on:includingOwnWindowIDs: [CGWindowID])` (and the same for `globalRect`), after which
   CaptureEngine can delegate entirely to Core.
2. **Sendable warning in Core** (`ScreenCapturer.swift:68`): `MainActor.run { NSScreen.screens.filter … }` returns
   non-Sendable `NSScreen`s ("this is an error in the Swift 6 language mode"). Marking `capture(globalRect:)`
   `@MainActor` (SCK calls still run off-main while awaiting) removes it.
3. **App target wiring** (for the integrator): `AppAction.toggleDesktopIcons` should call
   `Services.capture.setDesktopIconsHidden(!Services.capture.desktopIconsHidden)`; the status-menu item title can
   read "Hide Desktop Icons" / "Show Desktop Icons" from `desktopIconsHidden`.
