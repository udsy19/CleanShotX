# CaptureKit — reconstructed feature spec

Scope: area / previous area / fullscreen / window / self-timer / All-In-One captures, the shared selection
overlay, freeze screen, crosshair + magnifier, edge snapping, window backgrounds, desktop-icon hiding and the
global color picker. Evidence comes from `docs/re/raw/classes-digest.md` (class / ivar / selector names),
`strings-app.txt` and `ui-sentences.txt` of CleanShot X 5.0.1.

## 1. Architecture in the original

| CleanShot class | Role (evidence) | Shotcraft counterpart |
|---|---|---|
| `ScreenCapture` (ivars `task, lastCaptureRect, wasShiftPressed, wasControlPressed, lastUsedScreenshotAction`) | capture orchestration; remembers last rect; reads Shift at capture time | `CaptureService` |
| `ScreenTools` (`freezerController, crosshairController, selfTimerOverlay, windows, isSwitchingModes`) | owns per-capture helpers | `CaptureService` + `SelectionSession` |
| `FSOverlay : NSWindowController` (`curtainView, infoLabel, area, screenRect, first, last, helperPoint, screen, controlsAreVisible, spaceIsDown, rectangleBeforeMouseDown`; sels `escapePressed rectangleChanged ratioChanged mouseDown: mouseDragged: mouseUp: performKeyEquivalent:`) | one full-screen overlay per display: dimming curtain, info label, drag-to-select, Space handling | `SelectionSession` + `OverlayPanel` / `OverlayView` |
| `FSWindow : NSWindow` (`canBecomeKeyWindow, acceptsFirstResponder, cancelOperation:`) | borderless overlay window that can be key; Esc → `cancelOperation:` | `OverlayPanel` (non-activating `NSPanel`, `canBecomeKey = true`) |
| `OneOverlay : FSOverlay` (`controlsChildWindow, controlsView, selfTimerOverlay, windowNameLabel, displayId, screenFactor, freezedImage`) | All-In-One overlay: stays adjustable, shows controls, window-name label, frozen image | `SelectionSession` in `.allInOne` style |
| `OneControlsView`, `OneSizeControl` (`widthTextField, heightTextField, fullscreenButton, ratioButton, isFullScreen, size`; `openRatioMenuIn: ratioSelectedWithSender:`) | W×H fields, ratio menu, fullscreen toggle | `SizeControlView` |
| `OneRatioControl`, `RatioControlToggleButton`, `RatioMenuItem (ratio)`; strings `Aspect ratio`, `freeformMenuItem`, `oneOverlayLastSelectedRatio` | ratio menu, last ratio persisted | `AspectRatio` + `capturekit.lastAspectRatio` |
| `VideoSizeControl` | same control for recording | shared `SizeControlView` (adjustable sessions) |
| strings `oneOverlayFullscreen, oneOverlayRecord, oneOverlayScrollingCapture, oneOverlaySelfTimer, oneOverlayWindow, oneOverlayChevron` | All-In-One toolbar buttons | `AllInOneToolbar` |
| `Freezer : NSWindowController (screen)`, `FreezerController (freezers, watchDogTimer)` | per-screen frozen image windows | `FrozenScreens` (frozen image drawn as overlay background) |
| `CrosshairController (cursorUpdateTimer, modifierCheckTimer, mainLine, secondaryLine, loupe)` | full-screen guide lines | crosshair drawing in `OverlayView` |
| `Loupe : CALayer (pixelZoom, pixelCount, pickerSize, padding)` | magnifier, pixel grid | `LoupeRenderer` |
| `SnappingController (shortEdge, longEdge, cachedPixels, cachedRect, snapThreshold)`, `areaMoveBy:softSnapping:`, strings ` to disable snapping.` / ` to enable snapping.` | edge snapping while moving / resizing, modifier toggles it | `SelectionGeometry.snap*` (window + screen edges; hold ⌘ to disable) |
| `CSWindowFilter (windows)` | on-screen window list for hover selection | `WindowInfo.onScreen()` filtered in `SelectionSession` |
| `SelfTimerOverlay (seconds, secondsLabel, cancelButton, detectionTimer, intervalTimer)`, `CountDownOverlay` | countdown with cancel button | `CountdownController` |
| `WindowBackgroundSettings (_transparentWindowBackground, _windowBackgroundPadding, _captureWindowShadow)`; `_windowScreenshotPaddingOriginal` | window screenshot background | `WindowBackgroundComposer` |
| strings ` Shift while taking a screenshot to capture the window with wallpaper.` / `... to get a transparent background.` | Shift inverts the background preference | `CaptureService.captureWindowImage` |
| `IconOverlay (window, windowID)`, `IconOverlayController (overlays, isActive, savedState, observer; activeSpaceDidChange removeOldOverlays:)`, `WallpaperSettings (_overlayType, _plainColor, _customWallpaperName)`, defaults `captureWithoutDesktopIcons`, `hideDesktopIcons` | per-screen wallpaper windows hiding icons, re-rendered on Space change | `DesktopIconsController` + `WallpaperProvider` |
| `GlobalColorPicker (timer, view)`, `PickerView (gridSize, magnification, label, swatch, currentColor)`, `PickerWindow : NSPanel` | global color picker | `NSColorSampler` + hex copy |
| `DragMonitor (timer, drag; checkIfUserEndedDragging)` | detects end of a drag outside the app | not needed: we receive mouseUp directly |

## 2. Selection overlay (shared by every capture and by other modules via `selectArea`)

* One borderless window per `NSScreen`, frame = screen frame (covers menu bar and Dock), level just below
  pop-up menus so the ratio menu can open above it, `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary, .stationary, .ignoresCycle]`. Windows are non-activating panels that can become key,
  so the user's frontmost app keeps its active appearance while the overlay receives keys (`FSWindow`
  overrides `canBecomeKeyWindow`).
* Curtain (`curtainView`) dims everything outside the selection / hovered window. Crosshair cursor.
* Info label (`FSInfoLabel`, strings "Drag to select capture area.", " to select a window.") is centered on
  the active screen until the first mouse down.
* Drag to select. Modifiers while dragging (`spaceIsDown`, `rectangleBeforeMouseDown`):
  * **Shift** – square (1:1) selection; when moving, locks to the dominant axis.
  * **Option** – resize from the center (anchor = mouse-down point).
  * **Space held** – moves the whole selection with the mouse.
  * **⌘ held** – disables edge snapping.
* Window selection (`CSWindowFilter`, `windowNameLabel`): the front-most on-screen window under the cursor
  is highlighted; a click without drag selects it (returns its `CGWindowID` and frame). **Space** (or W in
  All-In-One, "Capture Window (Space/W)") toggles area ↔ window mode.
* Look (ui-reference §2): black 38% curtain (also before any drag); centred light instruction pill (white
  ~88%, 15 pt, 32 pt tall) with purpose-specific text ("Drag to select capture area.", "Drag to record a part
  of the screen. Press Space to select a window.", "Drag to capture the scrolling part of the screen.");
  1 pt white selection border with a faint dark outer stroke; white edge-midpoint pills (14×4) and corner
  squares as handles; white L-shaped corner brackets for recording/GIF/Studio selections.
* Dimension badge: dark-grey pill `rgba(60,60,67,0.85)`, white 11 pt "W x H" (points), above the selection's
  top-left corner (inside when there is no room); shown while drawing, moving or resizing.
* Window mode: hovered window undimmed, no tint; dark `#1C1C1E` 90% pill with the app name centred on it.
* Adjustable contexts (All-In-One, recording/GIF/Studio/scrolling selections): after mouse-up the selection
  stays with 8 resize handles; drag inside to move, drag a handle to resize (Shift keeps ratio, Option from
  center), arrow keys nudge 1 pt (Shift = 10 pt), Option+arrow resizes, Return / double-click confirms,
  Esc cancels. A confirm bar ("Record ↩", "Capture ↩"…) is shown under the selection.
* Crosshair mode (`_crosshairMode`): 1 px black-50% guide lines with a light halo across the screen, and the
  X / Y coordinates as two right-aligned lines just below-right of the cursor.
  Magnifier (`_showMagnifier`, "To enable magnifier, you must enable Crosshair Mode first.") — a 66 pt rounded
  `Loupe` (`pixelCount` 11, `pixelZoom` 6, 1.5 pt dark border) 12 pt below-right of the cursor (flips at screen
  edges) with a darker band through the centre row/column; coordinates are drawn just above it.
  Holding ⌘ temporarily shows crosshair + magnifier (and disables snapping).
* Snapping (`SnappingController`): selection edges snap to on-screen window edges and display edges within
  8 pt while creating, moving and resizing.
* Selection may span displays; it is clamped to the union of all screen frames. A display configuration
  change while the overlay is up cancels it.

## 3. Capture modes

* **Capture Area** – overlay (non-adjustable): mouse-up captures; click on a window captures that window's
  rect. Stores `lastCaptureArea` (`ScreenCapture.lastCaptureRect`). `options.rect` captures without UI.
* **Capture Previous Area** – recaptures `lastCaptureArea`; falls back to Capture Area when none.
* **Capture Fullscreen** – the screen under the cursor ("Active screen is the screen where your cursor is
  pointing.") or `options.displayIndex`.
* **Capture Window** – overlay starts in window mode; capture via ScreenCaptureKit single-window filter with
  `captureWindowShadow`, then the background preference (`windowBackgroundStyle`: transparent, desktop
  wallpaper, custom wallpaper, color; `windowBackgroundPadding`). Holding Shift at click time inverts
  transparent ↔ background. Non-transparent backgrounds add a synthetic soft shadow when the system shadow
  is not captured.
* **Self-Timer** – select an area/window, or press Return / F for the active screen ("This works in
  Fullscreen or Self-Timer modes only."). A countdown (`selfTimerSeconds`, ui-reference §7.3): 80 pt black
  disc with a bold 44 pt digit and a white progress arc, centred on the outlined area; a tick sound every
  second; hovering turns the digit into a cancel cross; Esc cancels. Then capture live.
* **All-In-One** (`OneOverlay`) – adjustable overlay with two dark glass bars (radius 14, 52 pt tall) centred
  14 pt below the selection (flipping above / inside when there is no room). Mode bar: vertical icon-over-label
  cells (58×44, 70% white, white-12% plate on hover) Area `viewfinder` (A/↩), Fullscreen `display` (F), Window
  `macwindow` (Space/W), Scrolling `arrow.down.to.line.compact` (S), Timer `timer` (T) | OCR `textformat` (O) |
  Recording `video` (R); G (Record GIF) works as a hidden accelerator, Esc closes. Size bar, 10 pt to the right:
  W x H fields (dark rounded plates, 15 pt monospaced digits) | ratio button `crop` + `chevron.down` (accent
  when a ratio is locked) opening the ratio menu (Freeform, 1:1, 4:3, 3:2, 16:9, 16:10, 9:16 and point sizes
  640×480 … 2560×1440). Recording/scrolling/Studio selections use the same size bar plus a fullscreen toggle,
  next to a confirm bar (Cancel / Record…). Remembers the area
  (`lastOneOverlayArea`, `_rememberOneOverlayArea`) when `rememberLastSelection` is on, and the last ratio
  (`oneOverlayLastSelectedRatio`).
* All screenshots are handed to `MediaPipeline.didCaptureImage(raw, scale:, mode:, actions:)` (which plays
  the capture sound); `options.actions` override after-capture actions.

## 4. Freeze screen

`_freezeScreen` / "Freeze screen when taking a screenshot": before showing the overlay every display is
captured (`Freezer` per screen, `freezedImage`) and drawn as the overlay background; the final image is cropped
from those pixels (stitched at the highest backing scale when spanning displays). Without freezing, the overlay
is transparent and the area is captured live after the overlay closes (own windows are excluded by
ScreenCaptureKit).

## 5. Desktop icons

`hideDesktopIcons` / "Hide desktop icons while capturing" (`captureWithoutDesktopIcons`) / "Toggle Desktop
Icons": one window per screen at `kCGDesktopIconWindowLevel + 1` showing the wallpaper
(`WallpaperSettings._overlayType` = desktop / custom image / plain color). Desktop images honor
`NSWorkspace.desktopImageOptions` (scaling, clipping, fill color); dynamic wallpapers that cannot be decoded
fall back to a ScreenCaptureKit grab of the Dock's wallpaper window. Overlays are rebuilt on display changes
and re-rendered on `activeSpaceDidChange` when "Update wallpaper when switching Spaces" is on. While
captures run with "Hide desktop icons while capturing", the overlays are shown temporarily and included
in the capture (ScreenCaptureKit `exceptingWindows`).

## 6. Color picker

`GlobalColorPicker` → system `NSColorSampler` loupe; the picked color is converted to sRGB and copied as
`#RRGGBB`; HUD "Copied #RRGGBB".

## 7. Settings used

`freezeScreenWhenCapturing, crosshairMode, showMagnifier, rememberLastSelection, selfTimerSeconds,
captureWindowShadow, windowBackgroundStyle, windowBackgroundColor, windowBackgroundPadding,
hideDesktopIconsWhileCapturing, wallpaperSource, customWallpaperPath, wallpaperColor,
updateWallpaperOnSpaceChange, showCursorOnScreenshots, lastCaptureArea, ocrKeepLineBreaks`.
Module keys: `capturekit.lastAllInOneArea`, `capturekit.lastAspectRatio`.
