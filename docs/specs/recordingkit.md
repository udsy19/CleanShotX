# RecordingKit — reconstructed spec

Scope: video/GIF screen recording, the recording overlays (setup bar, countdown, controls, dim,
click highlight, keystrokes, camera), and the video/GIF editor. Studio Mode is a separate module.

Evidence sources: the app's class metadata (ObjC/Swift class metadata from the arm64 slice),
its UI strings and app strings (UI strings). Cited as *digest* / *ui* / *strings*.

## 1. Object model in CleanShot X (digest)

| CleanShot class | ivars / selectors of interest | Super Screenshot equivalent |
|---|---|---|
| `ScreenRecorder` | `currentRecordingOverlay, recorder, durationTimer, recordingToGif, recordingRetinaVideo, cancelGifModal, watchdogTimer, cursorHighlighter, keyboardOverlay, gifsicle, audioMixer, showRecordingTimeInMenuBar, showRecordingControls`; `checkIfRecordingStarted`, `updateRecordingTimeLabel` | `RecordingService` (state machine) + `RecordingSession` |
| `RecorderOverlay : FSOverlay` | `recorderSettingsChildWindow, recorderControlsChildWindow, windowNameLabel, displayId, screenFactor, cameraOverlay, countDownOverlay`; `rectangleChanged`, `ratioChanged`, `performKeyEquivalent:` | `RecorderSetupOverlay` (area editor + setup bar) |
| `RecorderOverlayChildWindow` | `cancelOperation:` → Esc cancels | setup window `cancelOperation` |
| `RecorderSettingsView` | `settingsButton, highlightCursorButton, cameraButton, keystrokesButton, systemAudioButton, videoSizeControl, popover`; `startVideoRecordingClicked`, `startGIFRecordingClicked` | `RecorderSettingsPanel` |
| `MicrophoneAccessController` | `audioButton, vuMeter`; `openInputDevicesMenuIn:`, `setAudioDeviceWithSender:` | mic menu in setup bar (`AVDeviceMenuItem` ≙ menu item with `representedObject = uniqueID`) |
| `CameraAccessController` | `changeCameraShape…`, `changeCameraSize…`, `toggleCameraFullscreen…`, `changeCameraFlip…`, `setCameraDevice…` | camera menu + `CameraOverlay` context menu |
| `RecorderControlsView` | `stopButton, pauseButton`; `stopClicked pauseClicked restartClicked trashClicked` | `RecordingControlsPanel` |
| `StopButton : CSButton` | `label, levelLayer` (time label inside the stop button) | stop button with elapsed time |
| `CountDownOverlay` | `seconds, secondsLabel, cancelButton, progress, intervalTimer`; `secondElapsed`, `cancelClicked` | `CountdownOverlay` (click to skip, Esc to cancel) |
| `CursorHighlighter` | `style, initSize, targetSize, fadeSize, color, animate, eventMonitors` | `ClickHighlighter` (outline ring + dot, or filled disc) |
| `ClickHighlightSettings` | `_size, _color, _style, _animate` | color from `.clickHighlightColor`, style `recordingKit.clickStyle` |
| `CursorOverlay` | `cursorView, cursorUpdateTimer` | cursor-idle watcher toggling `showsCursor` |
| `KeyboardOverlay` | `box, label, fadeTimer, isDisplayingFullShortcut, displayAllKeys, eventListener` | `KeystrokeOverlay` |
| `KeyEventTapListener` / `MouseEventTapListener` | `eventTap, callback, queue, runLoop` | `NSEvent` global + local monitors |
| `CameraOverlay` | `videoPreviewLayer, captureSession, rectangle, contentPadding, margin`; `refreshSize refreshFullscreen refreshFlip` | `CameraOverlay` |
| `PausableTimer` | `timer, count, targetInterval` | `RecordingClock` (pure, pause-aware) |
| `VUMeter`, `PowerMeter(Aggregator)` | microphone level metering | level bar under the timer in the controls pill |
| `GIFProcessingPopup` | `gifProgressView`; `progressViewDidPressCancel` | `GIFProcessingPopup` |
| `Gifsicle`, `GIFUtility`, `GIFTrimmer` | external `gifsicle` task (`gifsicleOptimize`, `gifsicleTrim`) | `GIFEncoder` (ImageIO only, no gifsicle) |
| `VideoTrimmer` | `playerView, exportSession, trimButton`; `windowShouldClose:` | `VideoEditorWindowController` |
| `VideoPopup : ScreenRecordingPopup` | `removeAudioTrack` | "Include audio" toggle in the editor's Audio panel |
| `AudioMixer` | `micVolume, audioVolume, mergeAudioButton` | editor Volume slider; re-encodes mix all tracks into one |
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
2. **Setup overlay** (RecorderOverlay): outside of the area is dimmed, the area has a dashed border and 8
   resize handles, can be dragged or redrawn. The pre-record panel (ui-reference §7.1) is centred in the area
   (below / above it when the area is small): three 227-pt dark-glass blocks —
   **grid** (row 1: settings `slider.vertical.3` menu · editable W × H fields · full-screen toggle · aspect /
   size menu `crop` with Freeform, 16:9, 4:3, 1:1, 9:16, 640×480, 1280×720, 1920×1080 — a ratio locks resizing;
   row 2: microphone menu · system audio · camera menu · highlight clicks · keystrokes; active = white glyph +
   tick, inactive = 55 % white), **actions** ("Record GIF" with a GIF badge, "Record Video" `video.fill`;
   Return records the kind that was requested, ⌥Return the other), **Studio** pill ("Record in Studio Mode",
   only when `Services.studio` exists; "?" opens the "What is Studio Mode?" card). Esc cancels.
3. **Countdown** (`CountDownOverlay`): black 80-pt disc (90 %), white 44-pt bold digit, white progress arc
   each second, tick sound; click starts now, hover shows a cancel button, Esc cancels, Return starts.
4. **Recording** with ScreenCaptureKit (see §3). Controls pill (`RecorderControlsView`, #161616 @ 95 %, radius
   20): red `stop.circle` + red m:ss timer (mic level bar underneath when recording the mic) | `pause.circle` ⇄
   `play.circle` | `arrow.counterclockwise` | `trash` ("Are you sure you want to delete this recording?") |
   drag grip; separators are explicit-frame 1-pt views. Hidden when "Show controls while recording" is off.
   Menu bar shows time when "Display recording time in menu bar" is on.
5. **Stop** → finalize → GIF conversion when kind == gif → `MediaPipeline.didFinishRecording`.

## 3. Capture pipeline

- `SCContentFilter(display:excludingApplications:[self], exceptingWindows:[click, keystroke, camera])` —
  every Super Screenshot window (controls, alerts, Quick Access) is excluded, the decorative overlays are kept so
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
  starts at the first complete video frame's PTS (audio before it is dropped). Pause/resume are recorded as
  host-clock intervals (`PauseTimeline`); every sample is kept or dropped by **its own timestamp**, not by
  arrival time, and kept samples are re-timed by the total length of earlier pauses
  (`CMSampleBufferCreateCopyWithNewTiming`). Non-monotonic samples per track are dropped. The session ends at
  the pause-adjusted stop time (never before the last frame) so a static screen still yields the full
  duration.
- Failure handling: a failed `startCapture` / microphone / output setup cancels the writer, stops the mic
  and deletes the file. A writer that fails between appends, or a stream that stops with an error, is
  reported once; the session then finalizes what was written (HUD with the reason) or alerts if nothing
  could be saved. The session also stops when its display disappears
  (`didChangeScreenParametersNotification`) or the Mac goes to sleep. A Stop that arrives while the stream
  is still starting is honoured as soon as it runs.
- Codec: H.264 High (`low/medium/high`), HEVC for `original` quality and for any frame side > 4096 px
  (H.264 level limit). Bitrate = w × h × bpp × 30 × (fps/30)^0.6 with bpp low .02 / medium .04 /
  high .07 / original .12, clamped to 0.5…120 Mbit/s (strings: `bitrateKey`, `estimatedDataRate`).
- Disk check every 5 s: below 500 MB free → stop and alert "Recording stopped because your disk is almost
  full." (ui).
- Hide cursor when not moving: mouse idle ≥ 1.5 s → `updateConfiguration(showsCursor=false)`.

## 4. Overlays during recording

- **Dim**: borderless click-through window per screen, black 45 % outside the area with a faint 1-pt white
  border; with "Dim screen" off, a 2-pt red frame outlines the area instead (drawn outside the captured rect).
- **Click highlight**: click-through transparent window over the area's screen; `NSEvent` global + local
  monitors. Outline style: 36-pt ring (colour mixed toward white, 70 %, 3 pt) around a 12-pt solid dot;
  Filled style: translucent disc. Pops in 0.6→1.0, follows drags, fades over 0.35 s on release.
- **Keystrokes**: global `keyDown` monitor (needs Accessibility). Rounded rect (radius 14, height 52, 18-pt
  padding) 60 pt above the bottom-centre of the area, `rgba(30,30,40,.75)` + blur, SF Pro Rounded semibold
  28 pt. Shortcuts render as `⌃⌥⇧⌘K`; "Show only command keys" (default on) hides plain typing; fades after
  1 s idle; repeating the same shortcut bumps the HUD.
- **Camera**: borderless panel with `AVCaptureVideoPreviewLayer`; Circle / Square / Rectangle (16:9), heights
  120/160/240, 3-pt white border, shadow, bottom-right of the area inset 16 pt (follows the area while it is
  being adjusted until dragged). Click toggles full-screen camera (fills the area); drag moves; scroll /
  pinch resizes; context menu: device, shape, size, "Flip Camera", full screen, "Hide Camera". A spinner
  shows until the session runs.

## 5. GIF

No gifsicle: video is recorded at `.gifFPS`, then frames are sampled with `AVAssetImageGenerator`
(`maximumSize` = width ≤ `.gifMaxWidth`) and written by `StreamingGIFWriter`: each frame is quantized and
LZW-compressed by ImageIO as a single-frame GIF and its blocks are spliced into the output (local colour
table + our Graphic Control Extension, NETSCAPE2.0 loop forever). A multi-frame `CGImageDestination` holds
every frame until `Finalize` (measured ≈ 2 GB for 200 frames at 1280×720); streaming keeps memory flat. Delays are centisecond-quantised with error diffusion so total
duration matches (GIF delay unit is 1/100 s; fps clamped to ≤ 50 because browsers clamp delays < 2 cs).
Progress popup with Cancel ("User canceled GIF creation" — ui) and menu-bar progress.

## 6. Video editor (`VideoTrimmer`, `VideoPopup`; 5.0 Video Editor look)

- Window titled with the file name. Left rail "Audio" panel: "Include audio" switch and Volume slider
  (disabled with "This video has no audio."). Player (`AVPlayerView`, no controls) on black. Bottom bar:
  play/pause + time, then a thumbnail timeline with yellow trim handles and a playhead (drag handles to
  trim, click/drag to scrub; I / O set in/out at the playhead; Space plays the trimmed range).
- Title-bar buttons: "Convert to GIF", "Export…" (⌘S). Export sheet: Resolution (Original (W × H), 4k,
  1440p, 1080p, 720p, 480p, 360p, 240p — only sizes below the source, by short side), Quality slider
  (Low…Original), Audio switch, "Estimated file size ~X", "Replace the original video" (confirms "Do you want
  to replace the existing video?"), Cancel / Export. Progress sheet: "Exporting video…", bar, "~Xs
  remaining", percentage, "Cancel Export".
- Export: original quality, full size, unchanged volume → `AVAssetExportSession` passthrough over an
  `AVMutableComposition` (tracks inserted only where they overlap the trim range); otherwise an
  `AVAssetReader`→`AVAssetWriter` transcode with the recording bitrate model, audio tracks mixed into one
  stereo AAC track at the chosen volume (`AVAssetReaderAudioMixOutput`).
- Closing with unsaved edits asks to save (replaces the original with the last-used export settings).
- GIF media: same chrome — frame preview, timeline trim (by frame times), "Save as New GIF" / "Save";
  frames are decoded on demand from the source and re-encoded with `StreamingGIFWriter`.

## 7. Module-private keys

`recordingKit.cameraShape` (circle|square|rectangle), `recordingKit.cameraSize` (small|medium|large),
`recordingKit.cameraMirror`, `recordingKit.clickStyle` (outline|filled), `recordingKit.keystrokesShortcutsOnly`
(default true), `recordingKit.exportQuality`, `recordingKit.exportShortSide` (0 = original).

## 8. Not reproduced

"Your microphone is muted" detection, per-track mic/system volume, the 5.0 editor's Background/Zoom panels
and Cut tool (Studio Mode territory), Dock-icon export progress, the Studio info card's demo video,
"Do Not Disturb" toggling (no public API), crash recovery ("Your screen recording has been successfully
recovered."), and gifsicle optimisation.
