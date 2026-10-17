# OverlayKit — reconstructed spec

Scope: Quick Access Overlay (CleanShot "Popup"), pinned screenshots (CleanShot "FloatingOverlay") and
Capture History (CleanShot "MediaHistory"). Evidence is from the app's class metadata (ObjC
runtime metadata of the arm64 slice), app strings, UI strings and `defaults-sample.txt`.
Behaviour is inferred from class/ivar/selector names, UI strings and defaults keys, and implemented from
scratch; the Quick Access card's size, placement, hover-chrome metrics and motion were later read from the
binary's disassembly and a 120 Hz window-geometry recording (§1, tagged **binary** / **measured**).

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
| `QuickAccessSettings` | `_positionOnLeft`, `_moveToActiveDisplay`, `_overlaySize`, `_autoClose`, `_autoCloseMode`, `_autoCloseInterval`, `_closeAfterDragging`, `_closeAfterUploading`, `_askForDestinationWhenSaving` | Maps 1:1 onto Core keys `.quickAccessSide`, `.quickAccessScreen`, `.quickAccessSizeIndex` (`popupSize`), `.quickAccessAutoClose*`, `.quickAccessCloseAfter*`, `.quickAccessSaveBehavior`. |
| `DragMonitor` | `timer`, `drag`, `checkIfUserEndedDragging` | Drag end is also polled (drops into apps that don't report an operation). |

Strings: "Quick Access Overlay", "Close after dragging", "Close after uploading", "Close All Overlays",
"Save All Overlays", "Do you want to close all overlays?", "Open Quick Look (Space)", "Copy to clipboard (",
"Open Annotate tool (", "Open Video Editor (", "Move to Trash", "Rename", "Link has been copied",
"No files to restore...", "Restore Last Capture". Defaults sample: `deletePopupAfterDragging = 1`,
`popupAskForDestinationWhenSaving = 0`, `popupSize = 2`. Analytics events: `popupSlideOut`,
`popupSlideDown`, `popupRightClick`, `popupSpaceQuickLook`, `popupDoubleClickAnnotate`, `popupPin`.

### Behaviour (implemented)
UI parity follows `docs/specs/ui-reference.md` §4.
Geometry, hover chrome and motion below come from CleanShot X's binary (disassembly of `PopupController` /
`Popup` / `PopupBasic`, tagged **binary**) and a 120 Hz recording of its window geometry (**measured**); they
supersede earlier estimates.
- One borderless `NSPanel` (`.nonactivatingPanel`, never key) per card; level above pins;
  `.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle`. Panels are retained by the controller.
  (CleanShot uses one full-screen transparent window per screen holding all cards; per-card panels give the same
  on-screen geometry without a screen-sized window that could swallow clicks.)
- Size (binary): `.quickAccessSizeIndex` is CleanShot's `popupSize`, an index 0…4 into card widths
  `[140, 168, 210, 250, 350]` pt (`QuickAccessSize.widths`); the default is 2 (210 pt) when the main screen is
  wider than 900 pt, else 1 (168 pt). Settings shows it as a 5-tick slider. Every card is `width × width / 1.4`
  (210×150 at the default), whatever the capture's aspect: the thumbnail aspect-fills (crops) it — never
  letterboxed, animated GIFs included.
- Placement (binary; `QuickAccessLayout`, pure): 40 pt from the screen frame's side edge (left by default; right:
  `maxX − width − 40`). Card i (0 = newest, at the bottom) has its bottom edge at
  `screen.frame.minY + 100 + i × (height + 10)` — measured from the screen *frame*, not the visible frame, so the
  first card clears the Dock; 10 pt between cards. Cards that would reach the menu bar (`visibleFrame.maxY` less
  one gap) wait until space frees up. A Close All / Save All header (Super Screenshot's own, card-wide, 30 pt) sits
  10 pt above the stack when ≥ 3 cards are shown.
- Look: corner radius 17 pt on macOS 26+, 15 pt before (binary); a crisp edge (`CardStrokeView`: 0.5 pt black
  18 % hairline outside a 1 pt white 22 % inner stroke); window shadow; glass behind transparent captures. The
  thumbnail is decoded at the pixel size the fill needs (`QuickAccessLayout.thumbnailMaxPixel`, so crops are
  never upscaled) and drawn with trilinear minification; it is blurred only under the hover frost.
- Motion (measured; `QuickAccessMotion` curves driven per display frame by `PanelMotion`, a `CADisplayLink`
  at up to 120 Hz that moves/fades the panel — position and alpha are separate tracks):
  - Entrance: the card starts 69 pt toward the screen edge (x −69 on the left, +69 on the right) at alpha 0 and
    springs to its slot — an underdamped spring fitted to the recording (damping ratio ≈ 0.64, response ≈ 0.29 s):
    +5 pt overshoot at 0.19 s, within 1 pt of rest by 0.3 s — while alpha eases out 0 → 1 over 0.25 s. The
    entrance starts once the card's thumbnail is loaded, so it never slides in blank.
  - No capture fly-in: CleanShot does not fly the captured image into the card; it slides the card in.
  - Exit (close, after drag/save/copy): the reverse — 69 pt toward the edge while fading out, 0.2 s ease-in.
  - Reflow: when a card is removed (or the stack slides down / settings change) the other cards spring to their
    new slots with the entrance spring.
  - Hover chrome fades in/out over 0.15 s.
  - With Reduce Motion, entrances/exits are plain fades and reflows are instant.
- Hover (binary, `PopupBasic`): the thumbnail dims + frosts (dark tint plus a light within-window blur). Two
  stacked, centred pills — **Copy** (top) and **Save** (bottom), 10 pt apart — each 27 pt tall with a 12 pt
  `.medium` `labelColor` title under the `.aqua` appearance (dark text), 9 pt title padding each side
  (width = title width + 18), both as wide as the wider one. Four circular corner buttons inset 6 pt, side
  `18 + 2 × size index` (22 pt at the default), image-only SF Symbols at ≈ 0.45 × side in `labelColor`: Close
  `xmark` (TL), Pin `pin.fill` (TR; videos/GIFs: Quick Look `eye`), Annotate `pencil` (BL; videos/GIFs: Trim
  `scissors`), Upload `icloud.and.arrow.up.fill` (BR, per `.quickAccessShowUploadButton`). Pills and circles sit
  on an `NSVisualEffectView` (`.sidebar`, `.withinWindow`, `.active`, `.aqua`) pinned to the button's edges and
  fully rounded (radius = height / 2) — `OverlayButton` with the `.vibrant` backdrop; pins keep its `.light`
  backdrop. Super Screenshot adds a subtle hover/press tint on top of the vibrancy. `OverlayButton` draws its
  glyph/title with its own centred subviews and reports zero `alignmentRectInsets`: an `NSButton` cell with an
  image reports ≈2 pt/1.5 pt top/bottom insets, which made Auto Layout grow the frame into a tall oval. When the
  file is already saved (auto-save after-capture action) a Trash pill replaces Save. Video cards show the
  duration on hover and play muted.
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
- Hover chrome (fades in 0.12 s): close (TL) and lock (TR) as 22 pt light circles inset 8 pt (same
  `OverlayButton` as the cards); a "Drag me" pill at the bottom
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
  "↩ Restore" capsule below it. Gear (28 pt circle, like Close) menu: Keep History (1 day … 1 month, Forever) and "Clear History...".
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
