# OverlayKit — reconstructed spec

Scope: Quick Access Overlay (CleanShot "Popup"), pinned screenshots (CleanShot "FloatingOverlay") and
Capture History (CleanShot "MediaHistory"). Evidence is from the app's class metadata (ObjC
runtime metadata of the arm64 slice), app strings, UI strings and `defaults-sample.txt`.
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
UI parity follows `docs/specs/ui-reference.md` §4.
- One borderless `NSPanel` (`.nonactivatingPanel`, never key) per card; level above pins;
  `.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle`. Panels are retained by the controller.
- Layout (`QuickAccessLayout`, pure): card width `174 × size` (≈174×124 pt for 16:10 at the default size),
  height from the media aspect clamped to `[0.71, 1.25] × width`; the thumbnail is aspect-filled. 16 pt
  side/bottom margin, 12 pt spacing, newest at the bottom; cards that don't fit are hidden until space frees up.
  A Close All / Save All header sits above the stack when ≥ 3 cards are shown.
- Look: corner radius 12 pt (16 pt on macOS 26), 1 px white 20 % inner stroke, window shadow, glass behind
  transparent captures. Slides in from the configured edge with a slight-overshoot 0.35 s ease; slides out to it.
- Hover: thumbnail dimmed + frosted; centred **Copy / Save** pills (22 pt, white 80 %); 20 pt light corner
  buttons inset 6 pt — close (TL), pin (TR, images) or Quick Look eye (TR, videos), Annotate pencil / Trim
  scissors (BL), Upload (BR, per `.quickAccessShowUploadButton`). When the file is already saved (auto-save
  after-capture action) a Trash pill replaces Save. Video cards show the duration on hover and play muted.
- Hovered hotkeys (temporary global hotkeys): ⌘C, ⌘S, ⌘E (Annotate / Video Editor), ⌘P, ⌘U, ⌘W, Esc, Space.
- Hover state is re-derived from the pointer after every layout and once a second, so a card that moves under
  a still pointer never keeps hotkeys registered or its auto-close suspended.
- Screen: `.mainScreen` → primary display; `.activeScreen` → the cursor's screen, re-checked every second.
- Copy, Save and Pin close the card; Annotate keeps it. ⌥-click Save asks for a destination.
- Upload progress: the card listens to `CapturedMedia.uploadProgress`, so uploads started anywhere (card,
  after-capture action, history, pins) show the in-card ring + percentage, then a tick. UploadKit owns the
  "not set up" prompt, errors, sound and the "Link has been copied" HUD, so the card shows no duplicate text.
  The card closes 1.2 s later if `.quickAccessCloseAfterUploading`. A watchdog ends the progress state when
  UploadKit goes idle (uploads started elsewhere report no failure to the card).
- Drag the thumbnail out (file URL); on a successful drop the card closes if `.quickAccessCloseAfterDragging`
  unless ⌥ is held. Dropping at the screen edge or a two-finger swipe toward it dismisses the card; a swipe
  down (or "Temporarily Hide") slides the stack down so only the newest card's top edge peeks out — hovering
  it, or a new capture, slides it back.
- Double-click → Annotate / Video Editor.
- Context menu: Open Annotation Tool… / Open Video Editor…, Pin to the Screen | Upload to Cloud, Quick Look |
  Show in Finder, Open With ▸, Copy, Save As…, Rename…, Share ▸, Move to Trash | Temporarily Hide, Close,
  Save All, Close All….
- Auto close after `.quickAccessAutoCloseSeconds` when `.quickAccessAutoClose`; paused while hovered,
  dragging or uploading; performs `.quickAccessAutoCloseAction` first (an upload action keeps the card until
  the upload finishes).
- `CapturedMedia.didChange` refreshes thumbnail, duration and the Save/Trash pill.
- Closing never deletes the file. Closed media go on a "recently closed" stack used by `restoreLast()`.
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
UI parity follows `docs/specs/ui-reference.md` §6.
- Borderless non-activating `NSPanel` at `.floating`, all Spaces + full-screen auxiliary; shows the image at
  its point size (scaled down to fit 85 % of the visible frame), centred on the active screen, cascaded.
  Rounded corners 10 pt (on), shadow per `.pinShowShadow`, border off — each toggleable per pin.
- Drag anywhere to move; scroll or pinch scales around the cursor (10 %–500 %) with a dark "100%" pill;
  ⌥-scroll changes opacity (10–100 %). Middle-click closes.
- Hover chrome: close (TL) and lock (TR) as 22 pt light circles inset 8 pt; a "Drag me" pill at the bottom
  centre drags the file out (a temporary PNG is written for pins without a file).
- Lock: click-through (`ignoresMouseEvents`); a small unlock button floats over the top-right corner while the
  cursor is over the pin. With `.pinLockAndHideOnHover` the locked pin fades to 5 % on hover.
- Hovered keys: arrows move 1 pt (⇧ 10 pt), ⌘C copy, ⌘S save, ⌘E annotate, Esc/⌘W close; double-click → Annotate.
- Context menu: Copy to Clipboard, Save, Save As…, Capture Text (OCR), Open Annotation Tool…, Upload to Cloud,
  Zoom ▸, Opacity ▸, Show Shadow, Rounded Corners, Border, Lock, Close, Close All Pins.
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
  newest first, written atomically. All mutation and I/O happen on the main actor; bursts of changes are
  coalesced into one write on the next run-loop turn and flushed on quit.
- Pruning (`HistoryIndex.prune`, pure): drop entries older than `.historyRetentionDays` (0 = keep forever)
  and entries whose file is gone. When an expired entry is dropped, its file is deleted only if it is unsaved
  and lives in `AppPaths.media` or `AppPaths.recordings`. Runs at launch, on every add and hourly.
- `add` replaces an existing entry with the same id; `remove(_:)` drops one. `CapturedMedia.didChange` updates
  and persists entries and bumps a per-item revision so thumbnails reload.
- UI (ui-reference §10, 5.0 look): a full-width strip of dark glass (280 pt) across the middle of the active
  screen, hairline borders. Filter pills All / Screenshots / Videos / GIFs (selected = accent). A horizontal
  row of 180×120 pt thumbnails (radius 14, gap 24); the selected one has a 3 pt accent border and a blue
  "↩ Restore" capsule below it. Gear menu: Keep History (1 day … 1 month, Forever) and "Clear History...".
- Keys: ←/→ select, Space Quick Look, Return restore (→ Quick Access), ⌘E annotate, ⌘C copy, ⌘⌫ trash,
  Esc/⌘W close. Double-click → Annotate. Drag out. Context menu: Restore, Annotate, Pin, Quick Look, Copy,
  Save As…, Upload to Cloud, Show in Finder, Delete.
- The strip is a non-activating key panel (the frontmost app stays active); it closes on Esc, on a click in
  another app or after Restore. Empty states: "Capture History is disabled." (+ Open Settings) and
  "No files to restore...".
- `restoreLast()`: re-shows the most recently closed Quick Access card whose file still exists; else the newest
  history item not on screen; else HUD "No files to restore...".
- `clear()`: deletes unsaved managed files and empties the index.

## Deviations
- Quick Look uses `QLPreviewView` inside our own panel (as CleanShot's `QLViewController` does) instead of the
  shared `QLPreviewPanel`, whose controller lookup depends on the key window's responder chain — our panels
  never become key.
- CleanShot Cloud features (Raycast AI, cloud links) are out of scope; Upload goes through `Services.upload`.
- Not implemented from the QA context menu: Rotate Left, Flip Horizontally, Scale Retina to 1x, Resize…,
  Open in Mail, Print, Send to Raycast AI Chat, and the video card's "Remove the Audio". No "newest card"
  indicator (its look is unverified) and no per-upload cancel button (`UploadServicing` has only `cancelAll`).
