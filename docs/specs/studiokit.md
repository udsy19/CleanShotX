# StudioKit — Studio Mode ("Flow") reconstructed spec

CleanShot X 5.0.1 ships a second recorder called **Studio Mode** (internally *Flow*, class prefix `FL`).
It records the screen *without* the cursor while logging input events, then opens a project in a timeline
editor where cursor, zooms, background, camera and keystrokes are re-rendered. This document reconstructs it
from the binary and maps every piece to the Super Screenshot implementation in `Sources/StudioKit`.

Evidence sources: the app's class metadata (ObjC/Swift class metadata: ivars + selectors),
the app's strings, its UI strings, its Info.plist, and `strings`
over the arm64 slice (property-name tables that sit next to each other in `__cstring`).

## 1. Feature map (evidence → implementation)

| CleanShot class / string | Meaning | Super Screenshot |
|---|---|---|
| `Motion` ivars `recordInStudioMode, showCursor, mouseTracker, keyboardTracker, cameraRecorder, systemAudioInputWriter, microphoneAudioInputWriter, recordingPauseDate, recordingTimeOffset` | one SCStream recorder; Studio mode hides the cursor, adds trackers, separate audio writers, pause offsets | `StudioScreenRecorder`, `RecordingClock` |
| `FLMouseTracker` ivars `pollingInterval, cursorPollingTimer, cursorPollingQueue, recordingOrigin, recordingAreaFrame, pixelScaleX/Y, eventMonitors, lastRecordedMoveEvent`; string `com.cleanshot.FLMouseTracker.cursor` | cursor polled on its own queue, positions relative to the recorded area, clicks via event monitors | `InputTracker` (16 ms DispatchSourceTimer, area-normalized) |
| `FLCursorIdentifier` (`lastSeed, lastCursorType`), `FLCursorManager`, `CursorType` | which system cursor (arrow / I-beam / hand) was showing | `CursorKind`, sampled from `NSCursor.currentSystem` at 10 Hz |
| `FLKeyboardTracker` (`onTextKeyDown, previousModifierFlags`), "Keystroke capture requires …" | keystrokes need Accessibility | global keyDown monitor when `AXIsProcessTrusted()`; `events.keystrokesCaptured` |
| `FLCameraRecorder` (`captureSession, videoDataOutput, assetWriter, timeOffset, lastPTS, firstFrameLock`) + "Camera writer error", "Could not create camera input", "Camera device not found" | camera recorded to its own file, time-aligned | `CameraRecorder` → `camera.mov` |
| `FLMouseEventsBinaryCoder` | compact event storage | `CursorSample` encodes as `[t,x,y,kind]` arrays in `events.json` |
| `FLDocument` (`project, meta, videoURL, cameraURL, capturedWallpaper, projectURL`); UTI `com.cleanshot.videoproj` / `.cleanshotvideo` (package) | project is a package directory | `.superscreenshotvideo` package (`StudioPackage`) |
| `FLProject` ivars (clips, zooms, mouseEvents, keyboardEvents, recordingInfo, zoomAnimationStyle, motionBlur, audioConfiguration, showCamera, cameraScale, cameraShape, cameraPosition, flipCamera, resizeCameraDuringZoom, showCursor, hideCursorWhenNotMoving, hideCursorWhenTyping, cursorScale, cursorMovementStyle, cursorStyle, cursorClickEffect, cursorPressEffect, showKeystrokes, keystrokesScale, keystrokesStyle, keystrokesDisplayAll, keystrokesPosition, backgroundPaddingPercent, cornerRadius, backgroundShadowIntensity, background, aspectRatio, cameraTimeOffset) | the editable project | `StudioProject` + `StudioStyle` (same fields, own names) |
| `FLClip (id, startTime, duration)`, `FLCutMark (timestamp, trimmedSeconds)` | clips are source ranges; cuts are gaps | `StudioClip`, `ClipTimeline` |
| `FLZoom (id, startTimestamp, endTimestamp, zoomValue, mode, position)`; enum strings `followCursor`, `manual` | zoom segment with level, manual focus or follow cursor | `ZoomSegment`, `ZoomMode` |
| `FLSmartZoomAnalyzer` ivars `highIntensityZoom, normalZoom, clickLeadIn, zoomTrailAfter, minZoomDuration, maxZoomDuration, peakMinScore, neighborTimeRadius, neighborSpaceFraction, peakMinSeparation, dwellMinDuration, mergeGapThreshold` | auto-zoom from click clusters | `SmartZoomAnalyzer` (same parameter names) |
| `FLCache (oneEuroCache, phase1Cache, waypointCache, cachedBackground, cachedRoundedMask, cachedShadow)`; `OneEuroCacheKey`, `Waypoint`, `SmoothSegmentMap` | 1€-filtered cursor; cached background/mask/shadow | `OneEuroFilter`, `CursorTrack`, `Artwork` caches |
| `ZoomViewportState`, `halfViewportX/Y` | the visible window during zooms | `Viewport`, `ZoomPlanner` |
| `FLCompositor` (`startVideoCompositionRequest:`), `FLCompositionInstruction (trackID, cameraTrackID, containsTweening)` | custom AVVideoCompositing, camera as a second source track | `StudioCompositor`, `StudioInstruction` |
| `FLVideoPreviewController (ciContext, metalLayer, renderQueue)`, `FLPlayerController (player, composition, cameraReader, chaseTime, isSeekInProgress)` | CI-based live preview with chase seeking | `PlayerController` (AVPlayer + same compositor, chase seek) |
| `FLVideoEncoder (reader, writer, videoOutput, audioOutput, cancelLock)`, "Could not configure the video reader/writer", "Export was canceled." | export via AVAssetReader → AVAssetWriter | `StudioExporter` |
| `FLExportPanel (resolutionPopupButton, qualitySlider, estimateValueLabel, audioSwitch, estimateCalculator)`; "Estimated file size", "There is no audio in your video.", "Audio is muted in your project." | export sheet | `ExportPanelView` |
| `FLEncoderEstimateCalculator (videoInfo, useBitrateCompression)` | size estimate | `EncoderEstimate` |
| `FLRenderProgressView (progressBar, timeLabel, cancelButton)`, "Cancel Processing...", "Are you sure you want to stop the processing?" | progress UI | `RenderProgressView` |
| `FLDockProgressTracker (sessions, dockProgressView)` | Dock tile progress | `DockProgress` |
| `Flow` window controller selectors: `undo redo deleteSelectedObject splitClipAtPlayheadClicked splitZoomAtPlayheadClicked zoomInClicked zoomOutClicked zoomToFitClicked exportCurrentFrameClicked revealProjectInFinder saveChangesToProject windowShouldClose:`, ivar `lastSavedProject, lastKnownEditedState, editedLabel` | editor commands, dirty tracking | `EditorWindowController`, `EditorModel` |
| `FLEditor (historyPoints, currentHistoryIndex)` | snapshot undo | `EditorModel.history` |
| `FLEditableTitleField (renameDelegate)` | rename by editing the title | `EditorModel.rename` |
| `FLTimeline (scalePixelsPerSecond, cutMarks, zoomMarks, thumbnailGenerator, marker, hoverMarker, magnifyWithEvent:)`, `FLTimelineClip (initiedLeftTrim, initiedRightTrim, minimumClipDuration)`, `FLZoomBar`, `FLZoomMark (initiedMove, isPlaceholder)`, `FLThumbnailGenerator` | timeline with thumbnails, trims, zoom bar with placeholder | `TimelineView`, `ThumbnailProvider` |
| `FLZoomPositionControl (thumbnailLayer, spotlightLayer, anchorLayer)` | drag a spotlight to set focus | `ZoomPositionControl` |
| Shortcut ids `flowSplitClipAtPlayhead, flowSplitZoomAtPlayhead, flowZoomTimelineIn/Out/ToFit, flowNextClipEdge, flowPreviousClipEdge, flowNext10Frames, flowTimelineStart, flowToggleFullscreen, flowExportCurrentFrame` | keyboard commands | `EditorWindowController.handleKey` |
| Cursor style names `legacy, tahoe, goldengate, touch, modern` | cursor art variants | `CursorStyle` (macOS / inverted / touch — own vector art) |
| `RippleEffect`, "Ripple animation", `cursorPressEffect` | click ripple, press shrink | `CursorTrack.ripples`, `pressAmount` |
| `FLCameraShape`, `FLPosition`, "Shrink camera on zoom", `CameraFullscreenDidToggle`, "Click on camera to toggle Full Screen", "Toggle Camera Fullscreen" | camera bubble, corners, full-screen toggling | `CameraSettings`, `cameraFullscreen` segments |
| `FLAnimationsPropertiesView (motionBlurSlider, animationStyleControl)`, "Animation Settings" | zoom animation speed + motion blur | `ZoomAnimationStyle`, `ZoomEasing`, `motionBlur` (CIZoomBlur) |

## 2. Recording

1. `startStudioRecording(rect:)`: with no rect, `Services.capture.selectArea(purpose: .studio)` (Return = whole
   screen is handled by CaptureKit). The area is clipped to the display holding most of it.
2. Pre-record panel (ui-reference §7.1, 227 pt wide, two stacked dark-glass blocks under the area): a settings
   row — microphone menu, system audio, camera menu (opens a live 160 pt camera bubble with a 3 pt white
   border), keystrokes (asks for Accessibility), cancel — where active toggles are full white with a small tick
   and inactive ones 55 %; then the "Record in Studio Mode" pill (`movieclapper.fill`, "↩").
3. Countdown (`recordCountdown` / `recordCountdownSeconds`): 80 pt black disc, 44 pt bold digit, a ring that
   fills each second; hover shows a cancel button, Esc cancels back to the panel.
4. Capture: `SCStream`, display filter excluding Super Screenshot's own windows, `sourceRect` = area, native pixel size
   (`backingScaleFactor`), `showsCursor = false`, BGRA, `videoFPS` (30–60). H.264, HEVC above 4096×2304.
   System audio via SCStream audio, microphone via `AVCaptureSession`, each its own AAC track (system first).
5. `RecordingClock` maps every host timestamp (SCStream PTS, `AVCaptureSession.synchronizationClock`
   converted to the host clock, input-monitor callback time) to media time with pauses removed. All three files
   share one timeline starting at 0; samples during pauses are dropped. Click/scroll/key events use the
   event's own `NSEvent.timestamp` (same mach time base) and `cgEvent.location`, so they line up with frames even
   when the monitor callback runs late. ScreenCaptureKit only delivers frames when the screen changes, so the
   newest pre-start frame is written at 0 and the last frame is re-appended at stop.
6. Controls bar (§7.2): dark pill (`#161616` 95 %, radius 20) — red `stop.circle` + red m:ss timer, pause/resume
   circle, restart, trash, drag grip, separated by hairlines. Stop, Restart ("Are you sure you want to cancel this recording and
   start a new one?"), Delete ("Are you sure you want to delete this recording?"). `StatusBar.setRecording` every
   250 ms with the elapsed time when "Display recording time in menu bar" is on.
7. Stop → finalize writers → events.json → project.json (style from the last edited project, auto zooms from
   `SmartZoomAnalyzer` when enabled) → move package to `AppPaths.projects` → open editor.

### Package (`<name>.superscreenshotvideo/`)

`screen.mov` · `camera.mov` (optional) · `events.json` (`StudioEvents`: cursor `[t,x,y,kind]`, clicks, scrolls,
keys; normalized area coordinates, top-left origin) · `project.json` (`StudioProject`) · `autosave.json`
(unsaved edits, crash recovery) · `background-*.ext` (user image copied in, keeps the package portable).

## 3. Editing model

* **Clips** are source ranges; the output timeline is their concatenation. Split at playhead (⌘B) or click with
  the Cut tool (B; V returns to Selection), delete clip (⌫), trim by dragging edges (bounded by neighbours,
  min 0.1 s). Grey scissors badges under the clip track mark every cut; removed ranges ≥ 0.5 s read "✂ 4s".
* **Zooms** and **camera full-screen segments** are stored in *source* time so they stay attached to the
  content when clips are cut; the timeline maps them through the clips (`outputTimeClamped`). Lane edits
  (`LaneMath`) never overlap: click adds a 2 s segment, drag creates one, drag body moves, edges resize,
  ⇧⌘B splits a zoom. Zoom context menu: Zoom Level ▸, Apply Zoom Level to All, Zoom Mode ▸, Split Zoom at
  Playhead, Duplicate, Remove, Remove All Zooms.
* **Undo/redo**: snapshot history (≤200), continuous gestures coalesce into one step.
* **Saving**: ⌘S writes project.json; every edit autosaves autosave.json after 1 s; closing with unsaved edits
  asks "Do you want to save your project before closing?" (Save / Don't Save / Cancel). All package writes go
  through one serial queue and pending autosaves are cancelled first, so a late autosave can never resurrect
  autosave.json after Save / Don't Save. Title edits rename the package immediately (blocked while exporting)
  and reload the media from the new location.
* **Compatibility**: every style struct, `StudioProject` and `StudioEvents` decode field by field with
  defaults, so projects from older/newer builds open (old 4-corner camera positions and top/bottom keystroke
  positions map onto the 3×3 grid; the old "muted" flag turns both audio sources off).

### Editor window (ui-reference §9)

Always dark (`#1E1E1E` window, `#232323` panels, 8 % white hairlines). Unified toolbar: centred editable title
plus grey "Edited", then ⋯ (Save, Export Current Frame, Reveal in Finder), grey `icloud.and.arrow.up`
(Export & Upload) and the blue "Export" button. Left: 44 pt icon rail — Cursor, Keystrokes, Audio, Camera,
Background, Animations; the selected icon sits on a 28 pt accent square — with the scissors (Cut tool) pinned at
the bottom, level with the transport. Beside it the 245 pt properties panel (11 pt section labels, switches,
sliders with value labels, segmented pairs whose selected half is blue, popups, checkboxes, 3×3 position
grids). Selecting a zoom swaps in the contextual Zoom panel (level %, Apply to All, Follow Cursor | Manual with
the focus mini-preview, Animation Settings popover). Preview centred with an expand button (⌘F full screen);
transport: "00:08 / 00:22", ⏮ ▶ ⏭, "– slider +" timeline zoom. Timeline (full width): ruler with faint
gridlines, zoom track (grey "Zoom 150%" bars, selected = accent, "+ Click or drag to add zoom"), clip filmstrip
(8 pt radius, small gaps), cut badges, camera track; red 1 pt playhead with a rounded pin head.

## 4. Smart zoom (FLSmartZoomAnalyzer)

Clicks (mouse-down) are clustered while consecutive clicks are ≤ `neighborTimeRadius` (3 s) apart and within
`neighborSpaceFraction` (0.28) of the running centroid. Each cluster → zoom from first click − `clickLeadIn`
(0.7 s) to last click + `zoomTrailAfter` (1.6 s), at least `minZoomDuration` (1.6 s), chopped at
`maxZoomDuration` (9 s). ≥3 tight clicks (spread < 0.08) use `highIntensityZoom` (2.4×) else `normalZoom`
(1.8×); spread > 0.18 switches to follow-cursor. Neighbours closer than `mergeGapThreshold` (1 s) looking at
the same place merge; otherwise overlaps are trimmed.

## 5. Rendering (one function for preview and export)

`StudioRenderer.render(scene:screen:camera:at:canvas:)`, called by `StudioCompositor` for AVPlayer, AVAssetReader
and AVAssetImageGenerator alike. Per frame, at source time *t*:

1. Canvas = recording (minus inset) extended to the aspect ratio; export scales it to the preset.
2. Viewport from `ZoomPlanner`: each segment eases in over its first `animation.duration` and out over its last;
   gaps < 0.6 s hand over directly; interrupted transitions start from the current viewport. Follow-cursor
   centres on a heavily 1€-smoothed cursor path; the viewport is clamped inside the canvas.
3. Background (none / colour / gradient preset / wallpaper / image, aspect-fill), shadow (blurred rounded rect),
   screen placed with padding and rounded mask — all transformed by the single zoom affine so nothing is
   resampled twice.
4. Cursor: smoothed position (1€, `smoothing` 0…1), vector arrow / I-beam (CoreGraphics) or system hand,
   scaled with the zoom, press shrink, idle/typing fades. Click highlight (0.45 s, grows 0.6→1 and fades):
   Outline = light ring around a solid dot, or Filled = translucent disc, in a named colour (Blue…White).
5. Optional CIZoomBlur proportional to viewport speed (motion blur).
6. Camera (not zoomed): aspect-filled, mirrored, circle / rounded / square bubble on a 3×3 grid, shrinks up to 30%
   while zoomed, animates to full canvas inside full-screen segments; clicking it in the preview toggles a
   segment at the playhead.
7. Keystroke label (SF Pro Rounded semibold, Dark or Light style) on a 3×3 grid; shortcuts only or all keys
   (typing accumulates).

## 6. Export

Sheet (§8): format (MP4 H.264 / MP4 HEVC / GIF), "Resolution" (Original, 4k, 1440p, 1080p, 720p, 480p, 360p,
240p — each with its computed size, never upscaling), frame rate, "Quality" slider with a Very low…High label,
"Audio" switch, "Estimated file size". MP4: AVAssetReaderVideoCompositionOutput + AVAssetReaderAudioMixOutput
(per-source include toggles and volumes) → AVAssetWriter. GIF: AVAssetImageGenerator with the same video
composition → CGImageDestination. Progress sheet "Exporting video..." with "~Xs remaining", percentage and
"Cancel Export"; Dock tile progress bar. Export & Upload (⌘U) adds `.upload` to the after-recording actions. Result → `MediaPipeline.didFinishRecording(url, kind:
.video/.gif, mode: .studio, pixelSize, scale)`. "Export Current Frame as Image" (⇧⌘E) →
`MediaPipeline.didCaptureImage`.

## 7. Keyboard

Space play/pause · J/K/L shuttle · ←/→ frame, ⇧ 10 frames · ↑/↓ previous/next clip edge · Home/End ·
B cut tool · V selection tool · ⌘B split clip · ⇧⌘B split zoom · ⌫ delete selection · Esc deselect ·
F toggle camera full screen · ⌘F window full screen · ⌘=/⌘− zoom timeline, ⇧Z fit (also ⌘-scroll / pinch) ·
⌘Z/⇧⌘Z · ⌘S save · ⌘E export · ⌘U export & upload · ⇧⌘E export current frame · ⌘W close.

## 8. Not reproduced

* CleanShot Cloud itself — "Export & Upload" hands the file to UploadKit's configured destination.
* "Save As…" and the app-level File menu entries (the app target owns the main menu; the shortcuts work).
* Window-event / text-caret tracking (`_windowEvents`, `_textEvents`, `caretVerification`) used to zoom on the
  focused text field — smart zoom here uses clicks only.
* Passthrough export (`projectCanEncodeUsingPassthrough`) — every export re-renders.
* Custom export dimensions (width/height fields) — presets only.
