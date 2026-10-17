# RecordingKit — reconstructed spec

Scope: video/GIF screen recording, the recording overlays (setup bar, countdown, controls, dim,
click highlight, keystrokes, camera), and the video/GIF editor. Studio Mode is a separate module.

Evidence sources: `docs/re/raw/classes-digest.md` (ObjC/Swift class metadata from the arm64 slice),
`docs/re/raw/ui-sentences.txt` and `strings-app.txt` (UI strings). Cited as *digest* / *ui* / *strings*.

## 1. Object model in CleanShot X (digest)

| CleanShot class | ivars / selectors of interest | Shotcraft equivalent |
|---|---|---|
| `ScreenRecorder` | `currentRecordingOverlay, recorder, durationTimer, recordingToGif, recordingRetinaVideo, cancelGifModal, watchdogTimer, cursorHighlighter, keyboardOverlay, gifsicle, audioMixer, showRecordingTimeInMenuBar, showRecordingControls`; `checkIfRecordingStarted`, `updateRecordingTimeLabel` | `RecordingService` (state machine) + `RecordingSession` |
| `RecorderOverlay : FSOverlay` | `recorderSettingsChildWindow, recorderControlsChildWindow, windowNameLabel, displayId, screenFactor, cameraOverlay, countDownOverlay`; `rectangleChanged`, `ratioChanged`, `performKeyEquivalent:` | `RecorderSetupOverlay` (area editor + setup bar) |
| `RecorderOverlayChildWindow` | `cancelOperation:` → Esc cancels | setup window `cancelOperation` |
| `RecorderSettingsView` | `settingsButton, highlightCursorButton, cameraButton, keystrokesButton, systemAudioButton, videoSizeControl, popover`; `startVideoRecordingClicked`, `startGIFRecordingClicked` | `RecorderSetupBar` |
| `MicrophoneAccessController` | `audioButton, vuMeter`; `openInputDevicesMenuIn:`, `setAudioDeviceWithSender:` | mic menu in setup bar (`AVDeviceMenuItem` ≙ menu item with `representedObject = uniqueID`) |
| `CameraAccessController` | `changeCameraShape…`, `changeCameraSize…`, `toggleCameraFullscreen…`, `changeCameraFlip…`, `setCameraDevice…` | camera menu + `CameraOverlay` context menu |
| `RecorderControlsView` | `stopButton, pauseButton`; `stopClicked pauseClicked restartClicked trashClicked` | `RecordingControlsPanel` |
| `StopButton : CSButton` | `label, levelLayer` (time label inside the stop button) | stop button with elapsed time |
| `CountDownOverlay` | `seconds, secondsLabel, cancelButton, progress, intervalTimer`; `secondElapsed`, `cancelClicked` | `CountdownOverlay` (click to skip, Esc to cancel) |
| `CursorHighlighter` | `style, initSize, targetSize, fadeSize, color, animate, eventMonitors` | `ClickHighlighter` (ripple ring) |
| `ClickHighlightSettings` | `_size, _color, _style, _animate` | color from `.clickHighlightColor` |
| `CursorOverlay` | `cursorView, cursorUpdateTimer` | cursor-idle watcher toggling `showsCursor` |
| `KeyboardOverlay` | `box, label, fadeTimer, isDisplayingFullShortcut, displayAllKeys, eventListener` | `KeystrokeOverlay` |
| `KeyEventTapListener` / `MouseEventTapListener` | `eventTap, callback, queue, runLoop` | `NSEvent` global + local monitors |
| `CameraOverlay` | `videoPreviewLayer, captureSession, rectangle, contentPadding, margin`; `refreshSize refreshFullscreen refreshFlip` | `CameraOverlay` |
| `PausableTimer` | `timer, count, targetInterval` | `RecordingClock` (pure, pause-aware) |
| `VUMeter`, `PowerMeter(Aggregator)` | microphone level metering | not implemented (see §8) |
| `GIFProcessingPopup` | `gifProgressView`; `progressViewDidPressCancel` | `GIFProcessingPopup` |
| `Gifsicle`, `GIFUtility`, `GIFTrimmer` | external `gifsicle` task (`gifsicleOptimize`, `gifsicleTrim`) | `GIFEncoder` (ImageIO only, no gifsicle) |
| `VideoTrimmer` | `playerView, exportSession, trimButton`; `windowShouldClose:` | `VideoEditorWindowController` |
| `VideoPopup : ScreenRecordingPopup` | `removeAudioTrack` | "Remove the Audio" in editor |
| `AudioMixer` | `micVolume, audioVolume, mergeAudioButton` | not implemented (separate tracks kept) |
| `StatusMenuProgressIndicator` | `cancelGifClicked` | `StatusBar.setProgress` during GIF encoding |

`ScreenRecordingSettings` ivars (digest): `_videoFPS, _maxResolution, _downscaleRetina, _showRecordingControls,
_displayRecordingTime, _dimScreen, _rememberRecordingArea, _showCountdown, _doNotDisturb, _showCursor,
_highlightClicks, _showKeystrokes, _recordSystemAudio, _recordAudioInMono, _mergeAudioTracks, _gifFPS,
_gifMaxSize, _optimizeGifs, _gifQuality` — all map 1:1 onto the Core keys in `Settings.swift`
(Recording section), except `_mergeAudioTracks`/`_optimizeGifs`/`_gifQuality` (no Core key).

## 2. Flow

1. **Select** (`startRecording(kind, rect:)`): if `rect` is nil, `Services.capture.selectArea` with purpose
   `.recording`/`.gifRecording`, `initialRect` = `.lastRecordingArea` when `.rememberLastRecordingArea`.
   A window click yields that window's rect; an empty rect means "whole screen" (ui: "Drag to record a part
   of the screen.").
2. **Setup overlay** (RecorderOverlay): outside of the area is dimmed, the area has a border, 8 resize
   handles, can be dragged; a dimension label shows `W × H`. Under the area (or above / inside when there is
   no room) sits the setup bar:
   close · Video/GIF switch · microphone menu (devices + "Do Not Record Microphone" — ui) · system audio
   toggle ("Record system audio" — ui) · camera menu ("Record camera" — ui) · settings menu ("Show cursor",
   "Highlight clicks", "Show Keystrokes", "Hide cursor when not moving", "Dim screen while recording",
   "Record audio in mono", countdown, FPS, quality — ui) · "Start Video Recording" / "Start GIF Recording"
   button (ui). Esc cancels (`cancelOperation:`), Return starts.
3. **Countdown** (`CountDownOverlay`): `.recordCountdownSeconds` (default 3) with a tick sound each second;
   click skips, Esc cancels.
4. **Recording** with ScreenCaptureKit (see §3). Controls panel (`RecorderControlsView`): Stop (shows time),
   Pause/Resume, "Restart Recording", Delete ("Are you sure you want to delete this recording?" — ui).
   Hidden when "Show controls while recording" is off. Menu bar shows time when "Display recording time in
   menu bar" (ui) is on; the status item becomes the stop button ("Press to stop recording" — ui).
5. **Stop** → finalize → GIF conversion when kind == gif → `MediaPipeline.didFinishRecording`.

## 3. Capture pipeline

- `SCContentFilter(display:excludingApplications:[self], exceptingWindows:[click, keystroke, camera])` —
  every Shotcraft window (controls, alerts, Quick Access) is excluded, the decorative overlays are kept so
  they are burned into the video. The decorative windows are kept ordered-in (transparent when idle) so
  they exist in `SCShareableContent` when the filter is built.
- `sourceRect` = area in display-local points; output size = area × backing scale (or ×1 when
  "Scale Retina videos to 1x" — ui), **rounded down to even pixels** (4:2:0 chroma subsampling needs even
  dimensions); `sourceRect` is then re-derived from the even pixel size so no letterboxing occurs.
- `minimumFrameInterval = 1/fps` (`.videoFPS`, GIF uses `.gifFPS`), pixel format `420v`, BT.709 matrix,
  `showsCursor` per `.recordShowCursor`, idle frames (`SCFrameStatus != .complete`) are skipped.
- Audio: system audio via `capturesAudio` + `excludesCurrentProcessAudio`; microphone via `AVCaptureSession`
  + `AVCaptureAudioDataOutput` (LPCM forced to 48 kHz, 1 or 2 ch per "Record audio in mono"). Mic PTS are
  converted from the session's synchronization clock to the host clock (same timebase as SCK samples).
  "Microphone and system audio will remain on separate tracks." (ui) → two AAC tracks.
- `AVAssetWriter` (container per `.videoFormat`), all writer access on one serial sample queue. Session
  starts at the first complete video frame's PTS. Pause drops samples and accumulates the pause duration;
  later samples are re-timed with `CMSampleBufferCreateCopyWithNewTiming` (pts − offset). Non-monotonic
  samples per track are dropped. The session ends at the (offset-adjusted) stop time so a static screen
  still yields the full duration.
- Codec: H.264 High (`low/medium/high`), HEVC for `original` quality and for any frame side > 4096 px
  (H.264 level limit). Bitrate = w × h × bpp × 30 × (fps/30)^0.6 with bpp low .02 / medium .04 /
  high .07 / original .12, clamped to 0.5…120 Mbit/s (strings: `bitrateKey`, `estimatedDataRate`).
- Disk check every 5 s: below 500 MB free → stop and alert "Recording stopped because your disk is almost
  full." (ui).
- Hide cursor when not moving: mouse idle ≥ 1.5 s → `updateConfiguration(showsCursor=false)`.

## 4. Overlays during recording

- **Dim**: borderless click-through window per screen, black 45 % outside the area, 1 pt border just
  outside the area (not captured: excluded & outside `sourceRect`).
- **Click highlight**: click-through transparent window over the area's screen; `NSEvent` global + local
  monitors (no Accessibility needed for mouse). Mouse-down shows a filled ring in `.clickHighlightColor`
  that follows drags; mouse-up expands and fades it (ripple).
- **Keystrokes**: global `keyDown` monitor (needs Accessibility; requested through `Permissions`). Shortcuts
  render as `⌃⌥⇧⌘K`; plain typing accumulates characters; fades after 1.5 s; HUD at bottom-center of the
  area.
- **Camera**: borderless panel with `AVCaptureVideoPreviewLayer`, circle or rounded-rect shape, sizes
  S/M/L, mirror toggle, device menu (context menu); draggable; placed in the bottom-left of the area so
  it is recorded.

## 5. GIF

No gifsicle: video is recorded at `.gifFPS`, then frames are sampled with `AVAssetImageGenerator`
(zero tolerance, `maximumSize` = width ≤ `.gifMaxWidth`) and written via `CGImageDestination`
(`kCGImagePropertyGIFLoopCount = 0`). Delays are centisecond-quantised with error diffusion so total
duration matches (GIF delay unit is 1/100 s; fps clamped to ≤ 50 because browsers clamp delays < 2 cs).
Progress popup with Cancel ("User canceled GIF creation" — ui) and menu-bar progress.

## 6. Video editor (`VideoTrimmer`, `VideoPopup`)

- `AVPlayerView` (floating controls, `beginTrimming` for trimming; Space toggles play).
- Bottom bar: Trim, "Remove the Audio" ("Are you sure you want to remove the audio track?" — ui; disabled
  with "This video has no audio." when none), Quality (Original/High/Medium/Low) and Resolution
  (100/75/50/25 %) menus with an "Estimated file size" label (ui), "Convert to GIF", "Save as New Video"
  (ui), "Save" ("Do you want to replace the existing video?" — ui).
- Export: original quality at 100 % → `AVAssetExportSession` passthrough over an `AVMutableComposition`
  (trim/remove audio without re-encoding); otherwise an `AVAssetReader`→`AVAssetWriter` transcode with
  the same bitrate model as recording (writer scales via `AVVideoScalingModeResizeAspect`).
- Closing with an un-applied trim asks "Do you want to trim the video?" (ui).
- GIF media: animated preview + start/end frame sliders, re-encoded with ImageIO keeping original delays.

## 7. Module-private keys

`recordingKit.cameraShape` (circle|roundedRect), `recordingKit.cameraSize` (small|medium|large),
`recordingKit.cameraMirror`, `recordingKit.keystrokesShortcutsOnly`, `recordingKit.exportQuality`,
`recordingKit.exportScale`.

## 8. Not reproduced

VU meter / "Your microphone is muted" detection, AudioMixer (merging tracks with volume sliders),
"Do Not Disturb" toggling (no public API), crash recovery ("Your screen recording has been successfully
recovered."), and gifsicle optimisation.
