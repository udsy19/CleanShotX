# OverlayKit — reconstructed spec

Scope: Quick Access Overlay (CleanShot "Popup"), pinned screenshots (CleanShot "FloatingOverlay") and
Capture History (CleanShot "MediaHistory"). Evidence is from `docs/re/raw/classes-digest.md` (ObjC
runtime metadata of the arm64 slice), `strings-app.txt`, `ui-sentences.txt` and `defaults-sample.txt`.
No code was decompiled; behaviour below is inferred from class/ivar/selector names, UI strings and
defaults keys, and implemented from scratch.

## 1. Quick Access Overlay

### Evidence
| Class | Relevant ivars / selectors | Inference |
|---|---|---|
| `PopupController` | `popups`, `popupsRemoved`, `popupSizes`, `checkCurrentDisplayTimer`, `checkCurrentDisplay`, `slideDown`, `isSlidedDown`, `shouldSlideUpAfterClosingAnnotate` | One controller owns a stack of cards; remembers removed cards (→ "Restore Last Capture"); polls the display under the cursor and moves the stack there ("Move to active display"). |
| `Popup : NSWindowController` | `width`, `height`, `marginBottom`, `sideMargin`, `leftEdge`, `position`, `isHovered`, `holding`, `animationState`, `slideOut`, `forceSlideOut`, `scrollWheel:`, `mouseDragged:`, `draggingSuccess` | One window per card, positioned with a bottom + side margin on the left or right edge; slides in/out; scroll-wheel swipe dismisses; a successful drag reports back. |
| `PopupWindow : NSWindow` | `keyDown:` | Borderless window. |
| `PopupContainerView : CSUniversalEffectView`, `PopupBackgroundLayer`, `PopupContainerLayer` | `rightMouseDown:` | Blurred, rounded chrome; right-click menu. |
| `PopupDraggableImageView` | `draggingSession:sourceOperationMaskForDraggingContext:`, `draggingSession:endedAtPoint:operation:`, `acceptsFirstMouse:` | The thumbnail is an `NSDraggingSource` that works on first click in an inactive app. |
| `PopupBasic : Popup` | `copyButton`, `closeButton`, `saveButton`, `trashButton`, `closeTimer`, `timerDisabled`, `closeAll`, `saveAll`, `showMediaInFinder`, `saveAsAndClose`, `saveAndClose`, `openQuickLook`, `moveToTrash`, `openInAppWithSender:` | Hover buttons Copy/Save/close; auto-close timer; Close All / Save All; context menu Open, Show in Finder, Save As…, Move to Trash. Saving closes the card. |
| `UploadablePopup : PopupBasic` | `uploadButton`, `cloudProgressView`, `uploadClicked`, `copyLink`, `progressViewDidFinishSuccessfully`, `progressViewShouldSlideOutAfterFinish`, `mediaDidEdit` | Upload button → in-card progress → done state; optionally slides out after upload; observes media edits. |
| `PopupProgressView` | `progressIndicator`, `cancelButton`, `titleLabel`, `doneTitleLabel`, `doneTick` | Progress overlay with a done tick + title ("Link has been copied"). |
| `CircularProgress : NSView` | `progressLayer` | Ring progress drawn with a CAShapeLayer. |
| `ImagePopup : UploadablePopup` | `annotateButton`, `pinButton`, `firstClickTimestamp`, `openAnnotateWithSender:`, `openFloatingOverlay` | Image cards add Annotate + Pin; manual double-click detection → Annotate. |
| `ScreenRecordingPopup` / `VideoPopup` / `GIFPopup` | `quickLookButton`, `videoInfoView`, `durationLabel`, `sizeLabel`, `trimVideoWithSender:` | Video cards show duration; edit button opens the video editor. |
| `QuickLook` | `hotkeys`, `spaceHandler`, `escHandler`, `saveHandler`, `copyHandler`, `uploadHandler`, `editHandler`, `closeHandler` | Keyboard shortcuts are **temporary global hotkeys registered while a card is hovered** (the app is never activated). |
| `QLViewController`, `QLItem(previewItemURL)`, `QLMediaHistory` | `previewURL`, `isImage`, `openFloatingOverlay` | Quick Look is an in-app QL preview of the file URL. |
| `QuickAccessSettings` | `_positionOnLeft`, `_moveToActiveDisplay`, `_overlaySize`, `_autoClose`, `_autoCloseMode`, `_autoCloseInterval`, `_closeAfterDragging`, `_closeAfterUploading`, `_askForDestinationWhenSaving` | Maps 1:1 onto Core keys `.quickAccessSide`, `.quickAccessScreen`, `.quickAccessSize`, `.quickAccessAutoClose*`, `.quickAccessCloseAfter*`, `.quickAccessSaveBehavior`. |
| `DragMonitor` | `timer`, `drag`, `checkIfUserEndedDragging` | Drag end is also polled (drops into apps that don't report an operation). |

Strings: "Quick Access Overlay", "Close after dragging", "Close after uploading", "Close All Overlays",
"Save All Overlays", "Do you want to close all overlays?", "Open Quick Look (Space)", "Copy to clipboard (",
"Open Annotate tool (", "Open Video Editor (", "Move to Trash", "Rename", "Link has been copied",
"No files to restore...", "Restore Last Capture". Defaults sample: `deletePopupAfterDragging = 1`,
`popupAskForDestinationWhenSaving = 0`, `popupSize = 2`. Analytics events: `popupSlideOut`,
`popupSlideDown`, `popupRightClick`, `popupSpaceQuickLook`, `popupDoubleClickAnnotate`, `popupPin`.

### Behaviour (implemented)
- One borderless `NSPanel` (`.nonactivatingPanel`, never key) per card; level above pins;
  `.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle`. Panels are retained by the controller.
- Layout (`QuickAccessLayout`, pure): card width `200 × size`, height from the media aspect clamped to
  `[0.45, 1.25] × width`; 16 pt side/bottom margin; 12 pt spacing; newest at the bottom; cards that don't
  fit vertically are hidden until space frees up. A 30 pt header with **Close All / Save All** sits above the
  stack when ≥ 3 cards are shown.
- Screen: `.mainScreen` → `NSScreen.main`; `.activeScreen` → the cursor's screen, re-checked every second
  while no card is hovered (mirrors `checkCurrentDisplayTimer`).
- Slide in from the configured edge (0.25 s); slide out to the same edge when closed.
- Hover reveals: Copy / Save pills (centre), close (top-left), Annotate or Video Editor and Pin (top-right),
  Quick Look (bottom-left, "Open Quick Look (Space)"), Upload (bottom-right, if enabled and configured).
- While hovered, hotkeys ⌘C, ⌘S, ⌘A, ⌘P, ⌘U, Space, Esc, ⌘W are registered through `HotkeyCenter`
  and unregistered on exit.
- Copy, Save and Pin close the card after acting (CleanShot `saveAndClose`); Annotate keeps it.
- Save uses `MediaPipeline.save(media, askForDestination: .quickAccessSaveBehavior == .askForDestination)`.
- Upload → ring progress → tick + "Link has been copied" → closes after 1.2 s if `.quickAccessCloseAfterUploading`.
- Drag the thumbnail: dragging session with the file URL; card dims while dragging; on a successful drop the
  card closes if `.quickAccessCloseAfterDragging`. Dropping back at the screen edge, or a horizontal
  two-finger swipe toward the edge, dismisses the card.
- Double-click → Annotate (images) / Video Editor (videos, GIFs).
- Context menu: Open, Show in Finder, Rename…, Copy, Save As…, Upload, Pin, Move to Trash, Close.
- Auto close after `.quickAccessAutoCloseSeconds` when `.quickAccessAutoClose`; paused while hovered and
  while uploading; performs `.quickAccessAutoCloseAction` (if any) via `MediaPipeline.perform` first.
- Video cards: poster frame, duration badge, muted looping playback on hover. GIFs animate.
- `CapturedMedia.didChange` refreshes the thumbnail (after Annotate/Save/Rename).
- Closing never deletes the file; unsaved files stay in `AppPaths.media` for History. Closed media are pushed
  on a "recently closed" stack used by `restoreLast()`.
- Close All asks "Do you want to close all overlays?" if any shown media is unsaved.

## 2. Pinned screenshots

### Evidence
| Class | Relevant ivars / selectors | Inference |
|---|---|---|
| `FloatingOverlayController` | `overlays` | Owns all pins. |
| `FloatingOverlay : NSWindowController` | `thumbnailView`, `zoomLabel`, `zoomVisualBox`, `closeButton`, `lockButton`, `dragButton`, `image`, `mediaURL`, `magnification`, `frameBeforeMagnificationChange`, `imageIsTransparent`, `opacity`, `isHidden`, `mediaDidEditWithNotification:`, `magnifyWithEvent:`, `scrollWheel:`, `changeZoomWithSender:`, `changeOpacityWithSender:`, `openAnnotate`, `copyToClipboard`, `saveAs`, `extractText`, `toggleShadow`, `toggleRoundedCorners`, `toggleBorder`, `rightMouseUp:`, `performKeyEquivalent:` | Window per pin; pinch/scroll zoom with a % label; opacity & zoom menus; copy/save/annotate/OCR; per-pin shadow, rounded corners, border; follows media edits. |
| `FOCloseButton`, `FOLockButton(opacityBefore, isLocked)`, `FODragButton(draggingSession)` | | Hover close button, lock (restores previous opacity when unlocked), file-drag handle. |
| defaults strings | `floatingOverlayDropShadow`, `floatingOverlayRoundCorners`, `floatingOverlayShowBorder`, `floatingOverlayLocked`, `floatingOverlayUnlocked`, `floatingOverlayDrag` | Shadow/rounded/border preferences and analytics. |

Strings: "Pinned Screenshots", "Lock and hide screenshot on mouse over", "Toggle Pins Visibility",
"Pin to the Screen", "Choose and Pin an Image", "Pin Last Screenshot".

### Behaviour (implemented)
- Borderless non-activating `NSPanel` at `.floating`, all Spaces + full-screen auxiliary; shows the image at
  its point size (scaled down to fit 85 % of the visible frame), centred on the active screen, cascaded.
- Drag anywhere to move; scroll or pinch scales around the cursor (10 %–500 %, aspect kept) with a "100%"
  badge; ⌥-scroll changes opacity (10–100 %).
- Hover: close (top-left), lock (top-right), drag handle (bottom-right) that drags the file
  (a temporary PNG is written for pins without a file).
- Lock: the pin becomes click-through (`ignoresMouseEvents`); a small unlock button floats over its corner
  while the cursor is over the pin. With `.pinLockAndHideOnHover` the locked pin fades to 5 % on hover.
- Hovered keys: arrows move 1 pt (⇧ 10 pt), ⌘C copy, ⌘S save, Esc/⌘W close; double-click → Annotate.
- Context menu: Copy, Save As…, Annotate, Copy Text (OCR via `Services.text`), Zoom (25–200 %), Opacity
  (100/75/50/25 %), Show Shadow, Rounded Corners, Border, Lock, Close, Close All Pins.
- `toggleVisibility()` hides/shows all pins; `closeAll()`.

## 3. Capture History

### Evidence
| Class | Relevant ivars / selectors | Inference |
|---|---|---|
| `Media` | `creationDate`, `url`, `tempURL`, `projectURL`, `urlBookmark`, `cachedThumbnail`, `cachedDuration` | Persisted media record. |
| `MediaHistoryController` | `lastOverlayState`, `overlay` | Presents the history UI. |
| `MediaHistoryOverlay` | `collectionView`, `emptyLabel`, `filterButtons`, `filter`, `allMedia`, `filterSelectedWithSender:` | Grid of captures with filter buttons and an empty state. |
| `MediaHistoryItem` | `thumbnailView`, `videoInfoView`, `timestampLabel`, `restoreButton`, `copyClicked`, `openAnnotate`, `openFloatingOverlay`, `quickLookClicked`, `deleteClicked`, `restoreClicked`, `rightMouseDown:` | Per-item: timestamp, video info, Restore (→ Quick Access), Copy, Annotate, Pin, Quick Look, Delete; context menu. |
| `HistoryThumbnail` | dragging-source selectors | Items can be dragged out. |
| `HistorySettingsButton` | `clearHistoryClicked`, `historyCapacitySelectedWithSender:` | Gear menu: retention ("1 day", "3 days", "1 week", "1 month") + "Clear History...". |
| `MediaUtility` | `cleanMediaScheduler`, `cleanOldMedia` | Periodic pruning of old media. |

Defaults sample: `mediaHistory` is a JSON array of objects (`[{"url":"file:\/\/…`). Strings:
"Capture History is disabled.", "Are you sure you want to delete all files from history?",
"Clear History...", "No files to restore...", "Open Capture History".

### Behaviour (implemented)
- Index file `AppPaths.history/history.json`: `{"version":1,"items":[{id,url,kind,mode,date,width,height,scale,isSaved,uploadedURL,projectURL}]}`,
  newest first, written atomically.
- Pruning (`HistoryIndex.prune`, pure): drop entries older than `.historyRetentionDays` (0 = keep forever)
  and entries whose file is gone. When an expired entry is dropped, its file is deleted only if it is unsaved
  and lives in `AppPaths.media` or `AppPaths.recordings`. Runs at launch, on every add and hourly.
- `add` replaces an existing entry with the same id. `CapturedMedia.didChange` updates and persists entries.
- Window: filter (All / Screenshots / Recordings / GIFs), adaptive grid with thumbnail, date and pixel size,
  hover actions + context menu (Open in Quick Access, Annotate, Copy, Pin, Upload, Show in Finder, Move to
  Trash), double-click → Quick Access, drag out; gear menu with retention and "Clear History…". When
  `.historyEnabled` is off the window shows "Capture History is disabled." with an "Open Settings" button.
- `restoreLast()`: re-shows the most recently closed Quick Access card whose file still exists; else the newest
  history item not on screen; else HUD "No files to restore...".
- `clear()`: deletes unsaved managed files and empties the index.

## Deviations
- Quick Look uses `QLPreviewView` inside our own panel (as CleanShot's `QLViewController` does) instead of the
  shared `QLPreviewPanel`, whose controller lookup depends on the key window's responder chain — our panels
  never become key.
- CleanShot Cloud features (Raycast AI, cloud links) are out of scope; Upload goes through `Services.upload`.
