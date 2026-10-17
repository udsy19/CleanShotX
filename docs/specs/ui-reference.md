# CleanShot X — UI reference (for Shotcraft)

Implementation-ready description of CleanShot X 4.x–5.0.x UI, screen by screen. Nothing was captured from this
machine's screen and the app was never launched.

## 0. How to read this

**Evidence tags** (shown after each claim):

- **[V]** seen directly in an official image or video frame (cleanshot.com, official YouTube release videos).
- **[S]** taken from the app bundle (string tables in the app's strings and its UI strings, class ivars in
  the class metadata, nibs in its nib files, asset names from `Assets.car`).
- **[U]** unverified: inferred, estimated, or remembered. Treat these as defaults to tune.
- **[binary]** read directly out of CleanShot X's binary (disassembly). Supersedes [V]/[S]/[U] values.
- **[measured]** measured from a 120 Hz recording of CleanShot X's window geometry. Supersedes [V]/[S]/[U] values.

**Sizes.** Settings-window sizes come from 2x PNGs on cleanshot.com (1620×1320 px means 810×660 pt), so they are
accurate to about ±2 pt. Overlay and recorder sizes come from a 1440p video of a 1728-pt-wide display (≈1.48 px/pt),
so they are accurate to about ±15%. Marketing images are often zoomed. When sources disagree, I used the
un-zoomed video frames.

**Version note.** 5.0 (1 Sep 2026) added Studio Mode, a new Video Editor and a redesigned Settings window (a
sidebar replacing the old toolbar tabs). 4.8.x added the "Sleek new interface for macOS Tahoe": Liquid-Glass-like
overlays and cards. Where the two differ, both are described and 5.0 is the target.

**Sources.**
- cleanshot.com home, `/features`, `/screenshots`, `/screen-recording` and `/changelog`. These provided
  settings1–14, all-in-one, history, quick_actions, drag_and_drop, color-picker, show_crosshair, show_magnifier,
  header, quick-video, studio-mode, home/recording/* and home/annotate/*.
- Official YouTube videos: "Everything New in CleanShot 5.0" (fUB1s3RaD7c), 4.8 (o5ypDElAMto),
  4.7 (JyqCSh9m9oc), 4.6 (WOQsFWzOWlE) and 4.4 (FNHt4WUa13w).
- Shortcut lists from pie-menu.com/shortcuts/cleanshot and alchemists.io/articles/clean_shot.
- Reference images are not stored in this repository.

### 0.1 Global design tokens

| Token | Value | Evidence |
|---|---|---|
| `boxColor` (grouped-row background) | light `rgba(0,0,0,0.04)`; dark `rgba(255,255,255,0.03)` | [S] Assets.car named color |
| `secondaryWindowColor` | light `rgba(0,0,0,0.20)`; dark `rgba(255,255,255,0.20)` | [S] Assets.car named color |
| Accent | system accent (default blue `#0A84FF` dark / `#007AFF` light); the string "System Accent color" exists | [V][S] |
| Primary blue button | system `.borderedProminent`, white label, capsule on Tahoe | [V] |
| Overlay glass (AIO bar, recorder panel, QA card, history strip) | dark translucent glass: `NSVisualEffectView` `.hudWindow`/`.fullScreenUI` in dark appearance, about 60–70% dark tint, 1 px inner highlight stroke `rgba(255,255,255,0.12–0.18)`, soft shadow (y 8, blur 24, 35% black) | [V] |
| Dark HUD pills (recording bar, window-name pill, keystroke HUD) | near-black `#1C1C1E` at 85–95% opacity, white content | [V] |
| Light HUD pill (instruction hint) | white about 80% plus blur, text `labelColor` dark | [V] |
| Recording red | `#FF453A`-ish (systemRed) for the stop glyph and timer | [V] |
| Font | SF Pro (system). SF Pro Rounded style for keystroke HUD digits [U]. Monospaced digits for W×H fields and timers | [V] |
| Corner radii | settings grouped boxes 10–12 pt; overlay panels 16–18 pt; QA card 15 pt / 17 pt on macOS 26+ [binary]; pills fully rounded | [V] |
| Sounds | `grab-*.aif/caf` (shutter variants: 8bit, bigsur, classic, pop, subtle), `countdown.aif`, `startRecording.aif`, `stopRecording.aif`, `pauseRecording.aif`, `ocr.aif`, `uploadDone.aif`, `uploadError.aif`, `tink.aif` | [S] bundle Resources |

---

## 1. Menu bar menu

**Status item.** Template image `menubarIcon`. The glyph is a small rounded-square "sheet" with a diagonal peel or
notch, matching the app's peeling-card logo [V, shape approximate]. Use a custom template PDF; `camera.viewfinder`
is an acceptable SF Symbol fallback [U].

Alternate status icons [S]:
- `menubarStop`: recording in progress. Click to stop; the tooltip/string is "Press to stop recording".
- `menubarResume`: shown when paused.
- `menubarUpdate` / `menubarUpdateIndicator`: an orange dot (ivar `showOrangeIndicator`).
- `indeterminate1…8`: an animated progress icon during GIF render or upload.
- `loading0…8`.
- With "Display recording time in menu bar" on, the elapsed time text sits beside the stop icon [S][U].

**Menu** (5.0, macOS Tahoe glass menu; native `NSMenu`) [V frame 6:38 of the 5.0 video]. Icons are 16 pt
monochrome template glyphs on the left. Shortcuts are right-aligned in secondary color. Items in order:

| # | Title | Icon (asset → SF Symbol) | Default shortcut shown |
|---|---|---|---|
| 1 | All-In-One | `menubarAllInOne`: "1" in a circle → `1.circle` | ⇧⌘5 (only when user assigned system shortcuts) |
| 2 | Capture Area | `menubarCaptureArea`: four dashed corner brackets → `viewfinder` / `rectangle.dashed` | ⇧⌘4 |
| 3 | Capture Fullscreen | `menubarCaptureFullscreen`: display → `display` | ⇧⌘3 |
| 4 | Capture Window | `menubarWindow`: window with title bar → `macwindow` | — |
| 5 | Scrolling Capture | `menubarScrollingCapture`: down arrow → `arrow.down` | — |
| 6 | Self-Timer | `menubarSelfTimer`: stopwatch → `timer` | — |
| 7 | Capture Text (OCR) | `menubarOCR`: "Aa" → `textformat` | ⇧⌘2 (user-set in video) |
| 8 | Record Screen | `menubarRecordVideo`: video camera → `video` | ⇧⌘6 (user-set) |
| — | separator | | |
| 9 | Hide Desktop Icons / Show Desktop Icons (toggles) | `menubarHideDesktopIcons`/`menubarShowDesktopIcons`: eye with slash → `eye.slash` / `eye` | — |
| — | separator | | |
| 10 | Open... | `menubarOpenAnnotate`: pencil → `pencil` | — |
| 11 | Pin to the Screen... | `menubarPin`: pin → `pin` | — |
| — | separator | | |
| 12 | Capture History... | `menubarHistory`: clock with counter-clockwise arrow → `clock.arrow.circlepath` | ⇧⌘7 (user-set) |
| — | separator | | |
| 13 | About CleanShot... | none | |
| 14 | Settings... | none | ⌘, |
| — | separator | | |
| 15 | Quit | none | (no key equivalent shown) |

Verified against the running app (Setapp build, 2026-10): About and Settings share one group with no separator,
and there is no "Check for Updates..." item (Setapp handles updates).

The 4.4 menu (macOS Monterey) [V] had these extra items, which 5.0 hides by default or shows conditionally:
- "Capture Previous Area" (icon `menubarRepeat`, a circular arrow) after Capture Area.
- "Open from Clipboard" (`menubarFromClipboard`, a clipboard) after Open...
- "Preferences..." instead of "Settings...".

The 4.4 menu also showed the "Hide Desktop Icons" shortcut as ^⌥⌘. and "Capture History..." as ^⌥⌘Z.

The nib also wires these items [S]:
- "Activate..." (licence; Setapp builds hide it).
- An update item.
- "Past due" items with their own separators.
- A cloud section from `StatusMenuCloudController` / `StatusMenuCloudItem`. This shows recent uploads when "Show
  recently uploaded media" is on, with progress (`StatusMenuCloudProgressIndicator`) and "View All Uploads..." [S].

"Restore Last Capture" exists as a shortcut action [S]. The 4.x changelog calls it "Restore Recently Closed File"
in the menu [V changelog].

**Drag & drop onto the status item** is supported (`draggingEntered:`/`performDragOperation:`). It opens an image
in Annotate or pins it [S][U].

---

## 2. Area selection overlay (Capture Area / Record area / Scrolling)

**Window.** One borderless full-screen window per display, at a level above the menu bar, with a crosshair cursor.

**Freeze screen** (Settings → Screenshots → Capture → "Freeze screen when taking a screenshot"): when on, a
frozen screenshot is used as the background [S][V].

**Dim.**
- Screen dim outside the selection is black at about **35–40%** alpha [V 5.0 frames: the page turns mid-gray].
- Before any drag, the whole screen is dimmed.
- The selected rectangle is cut out at full brightness.
- In record mode with "Dim screen while recording" off, there is no dim. Only a red border marks the area
  [V alchemists text][U colour = systemRed, 2 pt].

**Instruction hint.** A centred light pill appears when the overlay opens.
- Style: white ~80% plus blur, height ~32 pt, horizontal padding 16 pt, fully rounded, SF Pro 15 pt regular, dark
  text [V].
- It fades out when you start dragging [U].
- Texts [S][V]:
  - "Drag to select capture area." (screenshots)
  - "Drag to record a part of the screen. Press Space to select a window." (recording)
  - "Drag to capture the scrolling part of the screen." (scrolling)

**Selection rectangle.**
- 1 pt white border with a faint dark outer stroke.
- Eight handles: small white **pills on the edge midpoints** (about 4×14 pt, 2 pt radius) and corners [V 4.6 AIO
  frame].
- In record mode, white L-shaped corner brackets (~14 pt arms, 2 pt thick) appear outside the rect corners [V 5.0
  frames].
- Drag inside the rect to move it. Space + drag moves it while you are still drawing (ivar `spaceIsDown`).
- ⇧ locks aspect ratio; ⌥ resizes from the centre ("Keep dimensions uniform") [S/alchemists].
- Edges snap to windows and screen edges (`SnappingController`, `CropSnappingController`) [S].

**Dimension readout.**
- In **Crosshair mode** the cursor shows two thin full-length lines (1 px, black ~50% with a white ~30% halo) across
  the whole screen [V show_crosshair].
- The X and Y coordinates appear as two right-aligned lines of small text (~10 pt, monospaced digits, dark with a
  light halo, no badge) just below-right of the cursor ("1 044" / "320") [V].
- While dragging, the size badge is a rounded dark-grey pill, e.g. "189 x 150" (white 11 pt medium,
  `rgba(60,60,67,0.85)`, radius 5 pt, padding 6×3 pt), placed above the top-left of the selection or near the
  cursor [V settings7 promo, placement U].
- Separator is " x " (lowercase x with spaces) in the badge and "×" in the AIO/recorder size fields [V].

**Magnifier (loupe)** (`Loupe : CALayer`, ivars `pixelZoom`, `pixelCount`, `pickerSize`, `padding`) [S]:
- Rounded square about **64×64 pt**, corner radius ~8 pt, 1.5 pt dark-grey border (`rgba(0,0,0,0.6)`) [V].
- Sits about 12 pt below-right of the cursor and flips at screen edges [U].
- Shows about 11×11 magnified pixels (nearest-neighbour) with a darker translucent **crosshair band** (one pixel
  wide at zoom, about 6 pt) through the centre row and column [V].
- Coordinates are drawn just above the loupe [V].
- The magnifier needs Crosshair Mode: "To enable magnifier, you must enable Crosshair Mode first." [S]. Holding ⌘
  temporarily shows crosshair plus magnifier [alchemists].
- Settings → Screenshots → Crosshair → "Crosshair Mode": Disabled / … popup, plus a "Show magnifier" toggle [V].

**Window mode** (Space or hover in window capture) [V 5.0 frames]:
- The hovered window renders undimmed, together with its shadow area. Everything else stays dimmed. There is no
  blue tint in 5.0. A light blue tint was used in older versions [U].
- A dark name pill is centred on the window (`windowNameLabel`), showing the **app name** (e.g. "CleanShot X").
  Style: `#1C1C1E` at 90%, white SF Pro 17 pt medium, height ~34 pt, horizontal padding 18 pt, fully rounded.
- Click to capture. Hold ⇧ to capture with a transparent background (Settings → Window Screenshots).

**Self-timer overlay** (`SelfTimerOverlay`: `secondsLabel`, `cancelButton`) and the record **countdown**
(`CountDownOverlay`) share one look; see §7.3.

---

## 3. All-In-One overlay (⇧⌘5-style)

Area selection (as §2) plus **two floating glass bars** centred **below the selection**, 12–16 pt under its bottom
edge [V aio.jpg, 4.6, 4.8 frames]. The bars flip above the selection or inside it when there is no room [U].
They are child windows (`OneOverlayChildWindow`, `OneControlsView`) [S].

**Bar A — mode bar** (≈ 410×52 pt, radius 14 pt, dark glass). There are 7 vertical buttons. Each is an icon (18 pt)
over a label (11 pt, `secondaryLabel`-white ~70%), with a button cell about 58×44 pt [V aio.jpg]:

| Order | Label | Asset → SF Symbol |
|---|---|---|
| 1 | Area | `oneOverlayArea`: dashed corner brackets → `viewfinder` |
| 2 | Fullscreen | `oneOverlayFullscreen`: display → `display` |
| 3 | Window | `oneOverlayWindow`: window frame → `macwindow` |
| 4 | Scrolling | `oneOverlayScrollingCapture`: arrow-down with a short bar on top → `arrow.down.to.line.compact` |
| 5 | Timer | `oneOverlaySelfTimer`: stopwatch → `timer` |
| — | 1 px vertical separator (white 12%) | |
| 6 | OCR | `oneOverlayOCR`: "Aa" → `textformat` |
| — | 1 px vertical separator | |
| 7 | Recording | `oneOverlayRecord`: video camera → `video` |

- Hover or selected cell: rounded rect (8 pt radius) filled white ~12%, with label and icon at 100% white [V
  "Window" hovered].
- The menu's keyboard hints are "Capture Area (A)", "Capture Fullscreen (F)", "Capture Window (Space/W)",
  "Scrolling Capture (S)", "Capture Text (O)" and "Record Screen (R)" [S]. Show these as tooltips; single-key
  accelerators work while the overlay is up.

**Bar B — size bar** (≈ 190×52 pt, same glass, 8–10 pt gap to the right of Bar A) [V]:
- Width field, "x", Height field. Each field is about 46×28 pt, filled `rgba(255,255,255,0.08)` or darker
  `rgba(0,0,0,0.25)`, radius 6 pt, white 15 pt monospaced digits, centred.
- Then a 1 px separator and a **ratio/crop button**: `crop` glyph plus `chevron.down` (`oneOverlayChevron`). It opens
  a ratio menu (`RatioMenuItem`). Entries are Freeform, 1:1, 4:3, 3:2, 16:9, 16:10, 9:16, plus custom sizes [U list].
  The checked ratio locks the selection (`RatioControlToggleButton`).
- A **fullscreen toggle** (two diagonal arrows `arrow.up.left.and.arrow.down.right`) sits between the fields and the
  separator in the recorder variant [V].
- Editing a field resizes the selection live. Return confirms and Esc cancels (`OneSizeControl`) [S].
- "Remember last selection" (Settings → Advanced → All-In-One) restores the previous rect [V].

**Behaviour.** Choosing Area, Window etc. performs the capture using the current rect. Timer starts the self-timer
on the rect. Recording switches to the recorder panel (§7.1). Esc closes. The overlay is excluded from OCR
(changelog 4.8.x) [V changelog].

---

## 4. Quick Access Overlay (QA) cards

**Placement.**
- Cards stack at a screen edge chosen by Settings → Quick Access → "Position on screen": **Left** (default) /
  Right [V settings4]. Strings also include "Place on the left/right/top/bottom" [S].
- The stack follows the active screen ("Move to active screen": "Active screen is the screen where your cursor is
  pointing.") [V].
- CleanShot holds the cards in one full-screen transparent window per screen [binary]; Shotcraft uses one panel per
  card with the same on-screen geometry.
- **Side margin 40 pt** from the screen edge (right: `screen.maxX − width − 40`) [binary].
- **Card i** (0 = newest, at the bottom) has its bottom edge at **`screen.frame.minY + 100 + i × (height + 10)`**:
  the first card sits 100 pt above the bottom of the screen *frame* (not the visible frame), clearing the Dock;
  10 pt between cards [binary].
- When a card is removed, the cards above slide down into place with the entrance spring [measured].

**Size.**
- "Overlay size" slider (5 ticks) is the `popupSize` index 0…4 into card widths **`[140, 168, 210, 250, 350]` pt**
  [binary][V settings4]. Default: index 2 (**210 pt**) when the main screen is wider than 900 pt, else 1 (168 pt)
  [binary].
- **Height = width / 1.4 for every capture** (210×150 at the default) [binary]. The thumbnail aspect-fills the card
  (cropped, never letterboxed).

**Card look (idle).**
- Corner radius **17 pt** on macOS 26+, **15 pt** before [binary].
- 1 px light inner stroke `rgba(255,255,255,0.2)`, shadow y 4–6, blur 16–20, 30% black [V].
- A subtle indicator marks the newest card [V changelog, look U].

**Motion** [measured, 120 Hz]:
- **Appear:** the card starts **69 pt toward the screen edge** (x −69 on the left, +69 on the right) at alpha ≈ 0 and
  springs to rest: **+5 pt overshoot at ≈ 0.19 s**, settled by ≈ 0.28 s (an underdamped spring, damping ratio ≈ 0.64,
  response ≈ 0.29 s); alpha ramps 0 → 1 over ≈ 0.25 s, ease-out.
- **Disappear** (close, after drag / save): the reverse — slides 69 pt toward the edge while fading out over ≈ 0.2 s,
  ease-in.
- The capture does **not** fly into the card: the card slides in.

**Card look (hover)** [binary, class `PopupBasic`]:
- The thumbnail is dimmed and blurred: dark overlay ~35% plus a light blur, fading in/out over ≈ 0.15 s [V][U timing].
- **Two centred stacked pills**: **"Copy"** on top and **"Save"** below, 10 pt apart. Each is **27 pt tall**, title
  `systemFont(12, .medium)` in `labelColor` under `NSAppearance(.aqua)` (dark text), button-cell title padding 9 pt
  each side (width = title width + 18); both forced to the wider width. Background: an `NSVisualEffectView`
  (`.sidebar`, `.withinWindow`, `.active`, `.aqua`) pinned to the button's edges, fully rounded (radius = height / 2).
- **Four corner buttons**: squares of side **18 + 2 × size index** (22 pt at the default), circular, inset **6 pt**
  from the card corners, with the same light visual-effect background; image-only SF Symbol glyph at ≈ 0.45 × side,
  `labelColor`. Buttons fade in on hover-enter and out on exit (≈ 0.15 s).

| Corner | Screenshot card | Video / GIF card |
|---|---|---|
| top-left | **Close** ✕ (`popupClose` → `xmark`) | Close ✕ |
| top-right | **Pin** (`popupPin` → `pin.fill`) | Quick Look eye (`popupQuickLook` → `eye`) |
| bottom-left | **Annotate** pencil (`popupAnnotate` → `pencil`) | **Trim** scissors (`popupTrim` → `scissors`) |
| bottom-right | **Upload** cloud-up (`popupUpload` → `icloud.and.arrow.up.fill`) | Upload |

- Older 4.x builds had close at top-right ("Changed close button location", 4.x changelog). The current layout puts
  close at top-left [V].
- When an auto-save After-Capture action is on, a **trash** button (`popupTrash` → `trash`) replaces Save [V
  changelog][placement U].
- Video cards show the duration on hover ("Recording time is shown when hovering over videos") and a sound/mute badge
  (`popupWithSound`, `menuItemMute`) [S][U placement]. GIF/video type badges are `popupGifFile`/`popupVideoFile`.
- Upload shows an in-card circular progress (`CircularProgress`, `PopupProgressView`), then `popupTick` (checkmark)
  and "Link has been copied" [S].

**Interactions.**
- Drag the thumbnail into any app (file promise). The card closes after dragging ("Close after dragging"; hold ⌥ to
  keep it) [V settings4].
- Hold ⌥ while dragging "Drag me" to keep it [V].
- Two-finger swipe toward the edge closes the card (swipe gesture control) [V changelog].
- Sliding the stack down temporarily hides it ("Temporarily hide Quick Access Overlay by sliding it down ↓").
- Double-click opens Annotate [U].
- Keys while hovered: ⌘C copy, ⌘S save, ⌘W close, ⌘U upload, ⌘E annotate, Space Quick Look [alchemists].
- Save button behaviour: Save to "Export location" (default) or ask; ⌥-click chooses the destination [V settings4].
- Auto-close: toggle, Action (e.g. "Save and Close"), Interval (e.g. "30 seconds"; 5 and 10 minutes exist) [V].

**Context menu** (right-click on the card), native `NSMenu` with icons on the first group [V quick_actions; S]:
- Open Annotation Tool... (pencil), Pin to the Screen (pin), Rotate Left (`menuItemRotateLeft`), plus "Flip
  Horizontally", "Scale Retina to 1x", "Resize..." and "Send to Raycast AI Chat" [S, exact order U].
- Separator.
- Upload to Cloud, Quick Look.
- Separator.
- Show in Finder, Open With ▸, Open in Mail..., plus Copy / Save as... / Move to Trash / Share ▸ / Print [S].
- Separator.
- Temporarily Hide, Close, plus "Save All" and "Close All..." [S].
- The video card adds "Remove the Audio" and "Open Video Editor" [S].

---

## 5. Annotate editor window

**Window.**
- Standard titled window with a **unified toolbar**: no visible title, traffic lights at left [V].
- Toolbar height ≈ 52 pt. Background is window chrome (light: translucent white glass; dark: dark glass).
- Optional "Always on top"; "Show Dock icon" while open [V settings10].
- Minimum size about 640×420 pt [U].

**Toolbar, left → right** [V 4.8 frame + 5.0 header image]. Buttons are about 28×24 pt with 16 pt glyphs. The three
leading buttons are separate rounded chips with a white/raised bezel. The tools form one grouped segmented control
(`ANSegmentedControl`) on a slightly darker capsule track. The selected tool gets a filled rounded rect: grey in
4.8, **accent blue capsule with a white glyph** in 5.0.

| # | Item | Asset → SF Symbol | Key |
|---|---|---|---|
| 1 | Crop & Resize | `annotateCrop` → `crop` | K (alchemists says C) |
| 2 | Add image / new screenshot (menu: Add New Screenshot ⇧⌘I, Add Screenshot From File ⌘I, Paste) | `annotateAddImageButton`: photo + plus badge → `photo.badge.plus` | |
| 3 | Background tool (toggle; blue when active) | `annotateNewBackground`: framed picture → `photo.on.rectangle` / `photo.artframe` | B |
| — | gap 12 pt, then the segmented group | | |
| 4 | Select / Move | `annotateCursorTool` → `cursorarrow` | V |
| 5 | Rectangle | `annotateRectangleTool` → `square` | R |
| 6 | Filled rectangle | `annotateFilledRectangleTool` → `square.fill` | F |
| 7 | Ellipse | `annotateEllipseTool` → `circle` | E |
| 8 | Line | `annotateLineTool` → `line.diagonal` | L |
| 9 | Arrow | `annotateArrowTool`: arrow pointing down-left → `arrow.down.left` | A |
| 10 | Text | `annotateTextTool`: bold "A" → `textformat.size.larger` / custom "A" | T |
| 11 | Pixelate / Blur / Redact | `annotatePixelateTool`: checkerboard → `checkerboard.rectangle` | P |
| 12 | Spotlight | `annotateFrameTool`: rect inside rect → `rectangle.inset.filled` | H |
| 13 | Counter | `annotateCounterTool`: "1" in a filled circle → `1.circle.fill` | C (S in old builds) |
| 14 | Draw (pencil) | `annotateDrawTool` → `pencil.tip` / `pencil` | D |
| 15 | Highlighter (smart text highlighter) | `annotateHighlightTool`: marker over "A" → `highlighter` | M |
| — | gap | | |
| 16 | Colour well: filled 16 pt circle in the current colour, plus `chevron.down` (opens palette §5.3) | `annotateColorPicker` | |
| 17 | Tool style / size: per-tool popover button, e.g. pen-nib with chevron or stroke-width preview | `annotateTextStyle`, arrow-style assets | |
| 18 | Draw-lock toggle (keep the tool active after drawing) | `annotateLocked`/`annotateUnlocked` → `lock.fill`/`lock.open` | |
| — | flexible space | | |
| 19 | **"Save as..."** (rounded rect button, white/raised) | | ⇧⌘S |
| 20 | **"Done"** (blue prominent) | `buttonDoneTick` | |

In crop mode the right side swaps to **"Cancel"** and **"Crop"** (blue), and the property bar shows crop options
(§5.2) [V 4.7].

### 5.1 Property / style controls (per tool)

These sit in the toolbar's right cluster: colour well, then style button, then lock [V]. Popovers are
`NSPopover`s with native controls [U].
- **Arrow styles** (4): Standard, Curved, Double, Fancy (`annotateArrowStyle{Standard,Curved,Double,Fancy}`). Hold
  ⌥ to invert direction (setting "Inverse arrow direction") [S][V].
- **Text styles** (7 predefined): Standard, Box, Rounded, Rounded Box, Outline, Monospaced, Monospaced Box
  (`annotateTextStyle*`). Text objects get a small square handle at the bottom-right corner that you drag to resize
  the font (4.6) [V].
- **Pixelate styles**: Pixelate, Blur, Secure Blur, Black Out (`annotatePixelateStyle*`, plus "-small" variants for
  the menu) [S].
- **Counter settings** (`annotateCounterSettings`, `ANCounterMenuTextField`): set the next number [S].
- Tool size: Increase `` ` `` / Decrease (shortcut listed as "+"); a stroke-thickness slider [V pie-menu].
- Objects get a drop shadow when "Draw shadow on objects" is on [V settings10].

### 5.2 Crop & Resize bar (`ANCropController`, `ANResizeControlViewController.nib`)

Left to right [V 4.7]:
- Ratio popup ("Freeform", …).
- W and H fields with a swap ↔ button (`annotateSwapButton`).
- Rotate (`annotateRotate`) and flip (`annotateFlip`) buttons, promoted in 4.8.
- "Image size:" popup showing "3840×2160 px ⌄".

The popup opens a **Resize** popover:
- "Width:" [field] and "Height:" [field], each with a lock toggle (`resizeLock`/`resizeLockOpen`) and a
  "pixels / percent" popup.
- Checkbox "Flatten Annotations" with the secondary note "(Can't be undone)".
- "Cancel" and "Resize" (blue) buttons [S nib][V].

The crop rectangle uses white **L corner brackets**, white edge-midpoint pills and a rule-of-thirds grid (white 30%).
Outside the crop is dimmed [V home crop.png].

### 5.3 Colour palette (4.8 custom picker, `ANColorPalette`, `ANColorPalettePanel`) [V color-picker.png]

The palette is a dark (or light, following appearance) popover panel with 14 pt radius.
- **Collapsed:** two columns of 22 pt swatch circles with a 6 pt gap.
  - Left column: 10 default colours, top to bottom: black `#000000`, red `#FF3B30`-ish, orange `#FF9500`, yellow
    `#FFCC00`, green `#34C759`, teal `#30C5BE`, blue `#007AFF`, purple `#8E5CF5`, pink `#FF2D55`, white `#FFFFFF`.
  - Right column: 10 "My Colors" slots, shown as dashed-outline empty circles until filled. You can reorder them by
    drag and delete them with a hover ✕.
  - Bottom: a colour-wheel button (`ANColorWheelButton`, rainbow circle) and a `<` chevron button that
    expands/collapses the picker [V].
- **Expanded** (about 340×480 pt), right pane:
  - Saturation/brightness square, 8 pt radius, with a circular white-ring thumb.
  - Hue slider and alpha slider (checkerboard track) with round thumbs.
  - A current-colour 30 pt circle.
  - Hex field ("9425E7", label "Hex") plus an eyedropper (`annotatePipette` → `eyedropper`).
  - R / G / B / Alpha numeric fields with labels below.
  - A full-width blue capsule **"+ Add to My Colors"**.
  - A grabber at the bottom edge [V].
- Accessibility setting "Show color names" shows names: "Light Blue", "Dark Gray", "Light Violet" etc. [S].

### 5.4 Background tool sidebar (`ANBackgroundSettings`)

Left sidebar about **240 pt** wide that slides in from the left, pushing the canvas. It has a light translucent
background and a vertical scroll [V header.png, 4.7 frames]. Top to bottom:
1. Preset row:
   - Popup ("Presets..." placeholder / preset name, e.g. "Brand preset", "My preset").
   - Trash icon (`annotatePresetTrash`) and "+" (`annotatePresetNew`).
   - The popup menu lists presets with a mini swatch, then "Apply Previous Settings", "Default Preset ▸" (submenu
     header "Automatically apply preset to all screenshots:", presets, ✓ None) and "Add New Preset..." [V 4.7].
2. **"None"** full-width button (selected state: 2 pt accent ring) [V].
3. **"Gradients"** header with a right-aligned "Show more ⌄ / Show less ⌃" link. Grid of **5 columns** of 40 pt
   rounded-square (10 pt radius) swatches with an 8 pt gap. 20 built-in backgrounds (`bg1…bg20`); the collapsed
   view shows 2 rows (10). The selected swatch has a 2.5 pt accent ring with a 2 pt gap [V].
4. **"Wallpapers"**: the desktop wallpaper thumbnail plus a dashed "+" tile to add a custom image [V].
5. **"Blurred"**: 3 tiles (blurred wallpaper, blurred light, grey) [V].
6. **"Plain color"**: 2 rows of 9 small 18 pt circles. Row 1 is saturated: black, white, red, orange, yellow, green,
   blue, purple, and a transparent-pattern tile. Row 2 is pastel versions plus a rainbow wheel [V].
7. Separator.
8. **"Padding"** slider (value appears on hover, e.g. "57") [V].
9. **"Inset"** slider plus an **"Auto-balance"** checkbox on the same row [V].
10. **"Shadow"** and **"Corners"** sliders side by side [V].
11. **"Alignment"**: 3×3 grid of tiny position glyphs (`annotateAlignment0–8`), centre selected by default. Next to
    it, **"Ratio"** popup ("Auto", 1:1, 4:3, 3:2, 16:9, 16:10, 9:16 …) [V].

Section headers use 12 pt semibold `secondaryLabel`. Sliders are small, with an accent fill [V]. Disabled state:
`disabledOptionsOverlay` dims options that don't apply ("These options are unavailable for window screenshots.")
[S].

### 5.5 Canvas & bottom bar

**Canvas** [V]:
- Neutral background (light `#FFFFFF`/very light grey; dark `#1E1E1E`) with the image centred and a soft drop shadow
  (y 2, blur 8, 25%).
- Transparent areas show a checkerboard (`annotateTransparentPattern`).
- Zoom with pinch or ⌘± ("Canvas Zoom").
- Drop zones with arrows (`annotateDropArrowTop/Left/Right/Bottom`) appear when you drag another image in, for
  placing it above, below, left or right. Snapping guide lines show while moving [V 4.8].

**Selection handles** [V redact.png]:
- Accent-blue 10 pt circles with a 1.5 pt white stroke at the corners.
- A 1.5 pt blue outline.
- Line and arrow objects get endpoint handles plus a midpoint control (curved arrow) [U].

**Bottom bar** (height ≈ 40 pt, same chrome as the toolbar) [V 4.8 frame]:
- **Left:** zoom popup **"100% ⌄"**, a small rounded bezel about 64×24 pt.
- **Centre:** **"Drag me"** pill (≈ 110×26 pt, rounded 6 pt, white raised bezel) with a "≡" grip glyph on each side
  (`dragButton`/`dragButtonTahoe`). Dragging it exports a file into another app.
- **Right:** 4 small bezel buttons (≈ 30×24 pt, 8 pt gap), in this order:
  1. Share (`annotateShare` → `square.and.arrow.up`)
  2. Pin (`annotatePin` → `pin.fill`)
  3. Copy (`annotateCopy` → `doc.on.doc.fill`)
  4. Upload to Cloud (`annotateCloud` → `icloud.and.arrow.up.fill`)
- Copy plus ⌥ copies without closing [V changelog].
- Raycast (`annotateRaycast`) appears when that integration is enabled [S].

---

## 6. Pinned screenshot (`FloatingOverlay`)

**Window.**
- Borderless and floating (always on top), showing only the image.
- **Rounded corners ~10 pt**, shadow and 1 px border are each optional (Settings → Advanced → Pinned Screenshots:
  "Rounded corners" on, "Shadow" off, "Border" off in the 5.0 screenshot) [V settings13].

**Hover chrome** [V home pin.png, 4.7 frame]:
- **Close ✕** at top-left and **Lock** at top-right (`floatingOverlayLocked`/`Unlocked` → `lock.fill`/`lock.open.fill`).
- Both are 22–24 pt circles, light grey `rgba(235,235,235,0.9)`, dark glyph, inset 8 pt.
- A **"Drag me"** handle (`floatingOverlayDrag`) at bottom centre [U placement].
- A zoom % label (`zoomLabel` inside `zoomVisualBox`, a dark rounded pill) appears while you scale [S].

**Behaviour.**
- Pinch or scroll to resize; ⌥/two-finger scroll changes opacity [V changelog].
- Arrow keys move it.
- **Lock mode** makes it click-through. "Lock and hide screenshot on mouse over" fades it when the cursor passes [S].
- Middle-click closes [V changelog].
- Right-click menu: Copy to clipboard, Save, Save as…, OCR (Capture Text), Open Annotate, Upload to Cloud, Zoom ▸,
  Opacity ▸, Shadow / Rounded corners / Border toggles, Close, Close All [S changelog][order U].
- "Toggle Pins Visibility" is a global shortcut [S].

---

## 7. Recording

### 7.1 Pre-record panel (`RecorderSettingsView`) [V 5.0 frames f8, f58; screen-recording.png]

The panel is centred in the selected area (or under it when the area is small). It is made of **three stacked
dark-glass blocks**, each ~**227 pt wide**, with a 10–12 pt gap between blocks [V measured]:

**Block 1 — settings grid** (2 rows × 5 columns, ≈ 227×70 pt, radius 16 pt). Cells are divided by 1 px hairlines
(white 8%).
- Row 1:
  - [Settings `slider.vertical.3` (`recorderSettingsButton`)], which opens a popover with recorder options.
  - [**W field** "1920" ×  **H field** "1080", 15 pt digits on a dark inset field, spanning 3 columns].
  - [Fullscreen toggle: two diagonal arrows].
  - [Crop/ratio `crop` (`recorderRatio`)].
- Row 2:
  - [Microphone `mic` (`recorderMicrophone`)]
  - [System audio: display with speaker waves (`recorderSystemSound`) → `speaker.wave.2` on `display`]
  - [Camera `video` (`recorderCamera`)]
  - [Highlight clicks: cursor with rays (`recorderHighlightCursor`) → `cursorarrow.rays`]
  - [Keystrokes: ⌘ in a rounded square (`recorderShowKeystrokes`) → `command.square`]
- **Active state:** white 100% glyph plus a small **checkmark** (`recorderTick`, 8 pt) under the icon. Inactive: white
  ~55%. Clicking mic or camera opens a device menu (`AVDeviceMenuItem`), with a VU meter for mic level [S].
- 4.6 had a soft coloured "light beam" glow under active toggles (`LightBeamView`) [S].

**Block 2 — actions** (2 rows, ≈ 227×74 pt, radius 16 pt, hairline between rows). Each row:
- Leading 20 pt icon, then a 15 pt medium white title, then a right-aligned shortcut glyph in 50% white.
- Row 1: [`GIF` badge (white rounded rect with dark "GIF" text, `recorderGifButton`)] **"Record GIF"** with "⌥↩".
- Row 2: [filled video camera `video.fill` (`recorderVideoButton`)] **"Record Video"** with "↩".
- Hover: row highlight white 8%.

**Block 3 — Studio** (single pill row ≈ 227×37 pt, fully rounded):
- [clapperboard `movieclapper.fill` (`recorderStudioButton`)] **"Record in Studio Mode"**.
- A trailing **"?"** in a 16 pt grey circle (`recorderInfoButton`) opens the **"What is Studio Mode?"** sheet [V]:
  - White card about 340×330 pt with a small blue clapper icon on top.
  - Title "What is Studio Mode?" in 17 pt bold.
  - Body (12 pt secondary): "Studio Mode records your screen as an editable project, giving you full control
    after recording. Add smooth zooms, customize your cursor, click effects, and fine-tune other details to create
    polished, professional videos in minutes."
  - A looping demo video (`studiomode.mp4`, radius 10).
  - Blue capsule **"Awesome!"**.

Older (4.6–4.8) builds have only blocks 1 and 2 [V format.png].

### 7.2 Recording controls bar (`RecorderControlsView`, `StopButton`) [V quick-video.png, camera.png, 4.6 frames]

Dark pill (≈ 196×40 pt; `#161616` at 95%, radius 20 pt, light hairline border), placed by default below the
recording area or at the screen bottom. It is **draggable** via a "⋮"/"≡" grip at the right end and is excluded from
the recording. The bar is split into segments by 1 px separators (white 10%):
1. **Stop + timer**: red ring-and-square glyph (`recorderControlStop`, `stop.circle`) plus a red **"1:24"**
   (`m:ss`, 15 pt semibold, monospaced digits). The segment is ~80 pt wide. A thin **audio level meter** sits under
   the timer when audio is recorded (`StopButton.levelLayer`, `VUMeter`) [V 4.6 narration][look U].
2. **Pause / Resume**: `pause.circle` (`recorderControlPause`) ⇄ `play.circle` (`recorderControlResume`), white.
3. **Restart**: counter-clockwise arrow `arrow.counterclockwise` (`recorderControlRestart`).
4. **Trash** `trash` (`recorderControlTrash`). Confirms with "Are you sure you want to delete this recording?" [S].
5. Drag grip (`recorderAnchor`) [V].

Each icon segment is about 40 pt wide with a 20 pt glyph. "Show controls while recording" toggles the bar.
`recorderMinimize` exists for a collapsed state [S].

**Menu bar during recording:** the status icon becomes a stop glyph (`menubarStop`), optionally with the elapsed
time, and clicking it stops the recording [S]. "Dim screen while recording" keeps the outside dimmed. When it is
off, a red frame outlines the area [V settings8].

### 7.3 Countdown (`CountDownOverlay`) [V 4.6 frame]

- A **black circle ~80 pt** in diameter (`#000` at 90%) with a white **SF Pro bold ~44 pt digit** ("3 → 2 → 1"),
  centred in the recording area.
- A short white progress arc/pill runs along the top inner edge (`progress` ivar).
- Hovering shows a cancel button (`cancelButton`).
- Plays `countdown.aif` each second.
- Enabled by "Show countdown" (Screen Recording → General). The self-timer uses the same component with
  `selfTimer`/`selfTimerEmpty` assets [S].

### 7.4 Click highlight (`CursorHighlighter`, `ClickHighlightSettings`: size, color, style, animate) [V click.png]

- Default **Outline** style: a ~36 pt circle ring, 3 pt stroke in **light blue** (`#7FB8FF`, about 70%) around a
  small 12 pt **solid blue dot** (`#0A84FF`) at the hotspot.
- **Filled** style: a translucent filled disc.
- Animation: ring scales 0.6→1.0 and fades over ~0.35 s ("Ripple animation") [U timing].
- Colours available via popup: Blue, Purple, … (cursorColor1–8) [S].
- Options: size slider, colour, style (Outline/Filled), animate toggle.

### 7.5 Keystroke overlay (`KeyboardOverlay`, `KeystrokeOverlaySettings`: size, style, position, displayAll, blurBackground) [V keystroke.png]

- Rounded rect (radius ~14 pt, height ~52 pt, horizontal padding 18 pt) placed **bottom-centre**, about 60 pt above
  the bottom edge (position is configurable on a 3×3 grid in Studio).
- **Dark** style: `rgba(30,30,40,0.75)` plus background blur, white glyphs. **Light** style: white 85% with dark
  glyphs.
- Text uses modifier glyphs then the key ("⌘F") in SF Pro Rounded semibold ~28 pt.
- It fades after ~1 s idle. Repeated presses get a small bump animation.
- Options: "Show only command keys" (default) vs "Show all keys".

### 7.6 Camera bubble (`CameraOverlay`) [V camera.png]

- **Circle** by default, about 160 pt diameter (scales with the recording area). It has a 3 pt white border and a
  soft shadow, and sits at the bottom-right of the area, inset about 16 pt.
- Shapes: Circle / Square / Rectangle.
- Draggable. **Click toggles full-screen camera** ("Click on camera to toggle Full Screen").
- Options: "Flip camera", "Shrink camera on zoom" (Studio).
- A loading spinner shows while the device starts.

---

## 8. Video editor / trimmer

**5.0 Video Editor.** Opening a plain MP4 (QA card scissors, "Open Video Editor", After Capture "Open Video
Editor") uses the **same window as Studio Mode** (§9). The left rail is reduced to the panels that apply (Audio:
"Include audio" toggle and Volume slider; Background; Zoom), and the title shows the file name with ".mp4" [V 5.0
frames 6:00–6:18].
- Trim by dragging the clip ends in the timeline, then cut with the scissors tool ("Cut Tool" B, "Split Clip at
  Playhead" ⌘B).
- Exports offer "Save as New Video" or replace ("Do you want to replace the existing video?") [S].

**Legacy trimmer (4.x, `VideoTrimmer`/`GIFTrimmer`).** An AVKit-style player window with trim handles below the
video ("Changed position of trimming controls to not cover the video") and a "Trim" button. It shows "Trimming
video..." progress. GIF trimming re-runs gifsicle [S][V changelog]. This is not needed for 5.0 parity.

**Export panel** (sheet, dark, about 300×260 pt, radius 12) [V 5.0 frame 5:18]:
- **"Resolution"** popup. Options: Custom, Original (W × H), 4k (…), 1440p, 1080p, 720p, 480p, 360p, 240p, each with
  the computed size in parentheses.
- **"Quality"** slider with a trailing value label (Very low … High).
- **"Audio"** toggle.
- **"Estimated file size"** with a right-aligned "~48.2 MB".
- "Cancel" and **"Export"** (blue).

**Progress.** A centred "Exporting video..." with a thin progress bar, a "~Xs remaining" left label, a percentage on
the right, and a "Cancel Export" button. The Dock icon shows progress (`FLDockProgressView`) [V][S].

---

## 9. Studio Mode editor (`FLEditor`, `FLWindow`, `FLTopBarView`, `FLTimeline`) [V 5.0 frames]

**Window.**
- Dark appearance is forced (background `#1E1E1E`; panels `#232323`; hairlines white 8%).
- About 1470×850 pt in the demo; full-size content with a hidden title.

**Top bar** (≈ 44 pt):
- Traffic lights.
- **Centred title** = project/file name ("CleanShot 2026-08-28 at 2.49.52 PM", 13 pt medium white) plus a grey
  **"Edited"** suffix when dirty.
- Right side: a grey rounded **cloud-upload** button (`icloud.and.arrow.up`), then a blue capsule **"Export"**.

**Left icon rail** (≈ 44 pt wide). Vertical 20 pt icons in `FLSidebarTogglebutton` style. The selected icon gets an
accent-blue 26 pt rounded-square fill with a white glyph. Order top to bottom:
1. Cursor: `flowCursorButton` (cursor with sparkle rays) → `cursorarrow.rays`
2. Keystrokes: `flowKeystrokesButton` → `command.square`
3. Audio: `flowAudioButton` → `speaker.wave.2.fill`
4. Camera: `flowCameraButton` → `video.fill`
5. Background: `flowBackgroundButton` → `photo`
6. Animations / motion blur: `flowAnimationsButton` (toggle-like circle with motion lines) → `circle.dashed`/custom

The **scissors** (`flowScissors`, Cut tool) is pinned at the bottom of the rail, aligned with the transport bar.

**Properties panel** (≈ 245 pt wide, scrolls). Section labels are 11 pt `secondaryLabel`. Controls are dark-native:
small sliders, segmented pairs where the selected half is blue-filled, popups and checkboxes.
- **Cursor:**
  - "Cursor" toggle "Show cursor".
  - "Size" slider with value ("2x").
  - "Style": three 40 pt square tiles (macOS arrow / alternative arrow / grey dot); the selected tile has a 2 pt
    blue ring.
  - "Motion": [Natural | Smooth].
  - "Clicks": ☑ "Press effect", ☑ "Ripple animation", "Color" popup (● Blue / ● Purple…), "Style" popup
    (Outline / Filled).
  - "Options": ☐ "Hide cursor when not moving", ☑ "Hide cursor when typing".
- **Keystrokes:**
  - "Keystrokes" toggle "Show keystrokes".
  - "Size" slider ("1x").
  - "Style" popup (Dark / Light).
  - "Position": 3×3 grid of small rounded tiles, the selected one blue.
  - "Options": radio "Show only command keys" / "Show all keys".
  - Empty state: "No keystrokes were captured in this video." [S]
- **Audio:**
  - "Microphone": "Include microphone" toggle and "Microphone volume" slider ("100%").
  - "System audio": "Include system audio" toggle and "System audio volume" slider.
  - Empty states: "No microphone was selected for this recording." and "This video has no audio." [S][V history.png]
- **Camera:**
  - "Camera" toggle "Show camera".
  - "Size" slider.
  - "Shape" popup (Circle / Square).
  - "Position" 3×3 grid.
  - "Options": ☑ "Flip camera", ☑ "Shrink camera on zoom".
- **Background:** the same structure as Annotate §5.4. Background "None", Gradients (2 rows of 5) with "Show more",
  Wallpapers (+), Plain color (2 rows of 9), "Aspect Ratio" popup (Auto, 1:1, 4:3, 3:2, 16:9, 16:10, 9:16 …),
  "Padding" (%), "Shadow", "Corners" (%) sliders.
- **Animations:** "Motion Blur" slider (Off / Low / Medium / High label at right) and "Zoom animations" [Smooth |
  Dynamic].
- **Zoom** (contextual, when a zoom segment is selected):
  - "Zoom level" slider plus "%" value.
  - "Apply Zoom Level to All" button.
  - "Zoom mode": [Follow Cursor | Manual]. Manual shows a mini-preview with a draggable focus rectangle.
  - "Animation": "Animation Settings" button.

Studio-only notices [S]: "Cursor/Keystroke/Camera customization is only available for videos recorded in Studio
Mode." and "Record your video in Studio Mode to use this option."

**Preview.**
- Centred canvas showing the background, the video with padding/corners/shadow, and the camera bubble.
- An expand icon at the top-right (`flowMaximize` → `arrow.up.left.and.arrow.down.right`) toggles full screen ⌘F.
- Transport bar (≈ 44 pt) under the preview:
  - Left: "00:08 / 00:22" (12 pt, current white / total grey).
  - Centre: ⏮ ▶ ⏭ (`backward.end.fill`, `play.fill`, `forward.end.fill`; 18 pt).
  - Right: timeline-zoom control "– ●──── +".

**Timeline** (full width under the panels):
- **Ruler**: "00:00, 00:01 …" 11 pt grey labels with faint vertical gridlines.
- **Playhead**: 1 px red line with a red rounded "pin" head (8 pt) above the ruler. A hover marker
  (`FLHoverMarker`) shows a thin grey line.
- **Zoom track** (≈ 28 pt high, rounded 6 pt track `#2A2A2A`):
  - Zoom segments are grey rounded bars labelled "Zoom 150%" (12 pt white). The selected segment is **solid accent
    blue**.
  - The empty track reads "+ Click or drag to add zoom".
  - The right-click menu on a segment has: Zoom Level ▸, Apply Zoom Level to All, Zoom Mode ▸, Split Zoom at
    Playhead, Duplicate, Remove, Remove All Zooms.
- **Clip track** (≈ 56 pt): a thumbnail filmstrip in a rounded 8 pt container. Clips are separated by small gaps.
- **Cut marks**: small grey circular scissors badges under the clip track at each cut. A deleted gap shows "✂ 4s".
- Shortcuts:
  - B = Cut tool, V = Selection tool
  - ⌘B Split Clip at Playhead, ⇧⌘B Split Zoom at Playhead
  - ⌘= / ⌘- timeline zoom, ⇧Z Fit Timeline to View
  - ⌘F Toggle Full Screen
  - ⌘E Export Video, ⌘U Export & Upload, ⇧⌘E Export Current Frame as Image
  - ←/→ frame step
  - Space Play / Pause [V settings shortcut list].

**Menus.** File menu: Save ⌘S, Save As..., Export... ⌘E, Export & Upload to Cloud... ⌘U, Export Current Frame as
Image... ⇧⌘E, Close Window ⌘W [V 5:42 frame; S].

---

## 10. Capture History (`MediaHistoryOverlay`)

**5.0/4.8 look** [V history.png]:
- A **full-width horizontal strip** across the middle of the screen, about 280 pt tall, in dark blurred glass
  (black ~55% plus heavy blur, hairline top and bottom borders white 15%). The desktop remains visible above and
  below.
- **Filter pills** centred at the top: "All" (selected: accent blue fill, white text), "Screenshots", "Videos",
  "GIFs" (unselected: white 15% fill, white text). Height ~28 pt, 13 pt semibold, 10 pt gap.
- Thumbnails form a horizontally scrolling row, each about 180×120 pt with radius 14 pt and a 24 pt gap. The
  selected thumbnail has a **3 pt accent-blue border**. A blue capsule **"↩ Restore"** button is centred below it
  (`return` glyph + "Restore", 15 pt semibold).

**4.4 look** [V]: a smaller frosted strip pinned to the top of the screen, with ~110×70 pt thumbnails and relative
time captions ("15 minutes ago").

**Behaviour** [alchemists, changelog]:
- ←/→ move the selection, Space Quick Look, Return restores (adds the item to QA), double-click opens Annotate.
- Drag a thumbnail out to another app.
- Right-click offers Annotate, Pin, Delete. "Clear History..." is also available.
- Empty state: "Capture History is disabled." / "No files to restore..." [S].
- Retention is set in Settings → Advanced: "Keep history" Never / 1 day / 3 days / 1 week / 1 month [V].

---

## 11. OCR feedback

- Capture Text uses the area selection (§2) with the hint "How to use the text recognition tool?" shown in
  first-run onboarding (`OCROnboarding`, `ocrOnboardingGuide` image) [S].
- **On success** the text is copied, `ocr.aif` plays, and a **HUD toast "Text has been copied"** appears [S]. The
  look is unverified [U]: implement a dark rounded HUD pill (`#1C1C1E` 90%, white 13 pt medium, `doc.on.doc` glyph,
  radius 10) at bottom-centre, fading out after 1.5 s.
- **No text:** "No text detected" in the same toast [S].
- **QR code / link detected** [V 4.6]: a small alert-style glass panel with the app icon, the title "Do you want to
  open this link?" [S] and the URL. Buttons:
  - Full-width blue **"Open Link in Browser"**.
  - Full-width grey **"Don't Open"**.
  - Checkbox "Don't detect links" underneath.
- Settings → Advanced → Text Recognition: Language ("Automatically Detect Language"), "Keep line breaks",
  "Detect links" [V].

---

## 12. Scrolling capture (`SGOverlay`, `SGControlsView`)

1. Area selection with the hint "Drag to capture the scrolling part of the screen." [S]. The first run shows an
   onboarding with three loops (area, scroll, orientation) and texts such as "Slowly scroll down the content",
   "Scroll Vertically or Horizontally" and "Move cursor here to start scrolling" [S].
2. After the area is chosen, the outside stays **dimmed** and the area is clear. Controls are small pills at the
   **bottom-centre inside the selection** [V 4.4 frame]:
   - A dark pill **"▶ Auto-Scroll"** (`scrollingCaptureAutoScroll`) sits above. The horizontal variant is
     `scrollingCaptureAutoScrollHorizontal` and appears at the right edge when horizontal content is detected [V
     4.8].
   - Below it, a dark pill **"✕ Cancel"** and a light pill **"✓ Done"**. Each is about 24 pt high, 12 pt medium,
     with a 6 pt gap.
   - There is also a help "?" (`scrollingCaptureHelp`).
   - A Start button (`scrollingCaptureStartButton`) is shown before capturing.
3. A **live stitched preview** docks **outside the selection, right side, bottom-aligned** for vertical captures (a
   white card ~165 pt wide that grows taller, with radius 6 and a shadow). For horizontal captures it docks **above**
   the selection as a strip [V].
4. Alerts appear as small panels (`SGAlert`, `PauseSGAlert`, `PermanentWarningSGAlert`): "Please slow down...",
   paused (`scrollingCapturePaused`), "too long" warning, "Auto-Scroll needs …" [S].
5. Done opens the result in QA or Annotate.

---

## 13. Settings window (5.0 redesign) [V settings1–14, 5.0 frames]

**Window.**
- **810×660 pt** default, resizable vertically. Uses Tahoe `NSSplitViewController` (`PRViewController`).
- Window background is white (light). The **sidebar is a floating inset panel**: 8 pt inset, ~220 pt wide, radius
  ~16 pt, very light grey `#F7F7F7` with a soft shadow (Tahoe sidebar material).
- Traffic lights sit inside the sidebar's top-left.

**Sidebar (`PRMenuControl`).**
- **Account header** at the top (y≈56–100 pt): a 36 pt circular avatar, then the name (13 pt semibold, e.g. "Laura
  Scott") with "CleanShot Cloud" below (11 pt secondary). Logged out it shows a generic person glyph with "Sign in"
  / "CleanShot Cloud".
- Item list: rows 36 pt tall at a 40 pt pitch.
  - Icon: a 24 pt **colour-filled rounded square (6 pt radius) with a white glyph**, like System Settings.
  - Title: 13 pt.
  - Selected row: rounded 10 pt pill `rgba(0,0,0,0.07)`.
  - Order and icons:

| Order | Title | Icon tile colour | Glyph (asset `pref*`) → SF Symbol |
|---|---|---|---|
| 1 | General | grey `#8E8E93` | gear → `gearshape.fill` |
| 2 | Shortcuts | grey | ⌘ → `command` |
| 3 | Quick Access | green `#1BA45B` | card with cursor → `rectangle.and.hand.point.up.left.fill` |
| 4 | Wallpaper | light cyan `#5AC8E0` | two overlapping rounded squares → `square.on.square` |
| 5 | Screenshots | blue `#1A8CFF` | camera → `camera.fill` |
| 6 | Screen Recording | red/pink `#E8344E` | video camera → `video.fill` |
| 7 | Annotate | orange `#FF8A1F` | pencil → `pencil` |
| 8 | Cloud | blue gradient | cloud → `cloud.fill` |
| 9 | Advanced | purple `#7D4CDB` | wrench + screwdriver → `wrench.and.screwdriver.fill` |
| (bottom) | About | grey | info → `info.circle.fill` |

The pre-5.0 order (toolbar tabs) was General, Wallpaper, Shortcuts, Quick Access, Recording, Screenshots, Annotate,
Cloud, Advanced, About [V 4.4/4.6 frames].

**Content area layout.**
- **Page title** (15 pt semibold, `labelColor`) at the top-left (x≈248, y≈24 pt) in a transparent toolbar.
  Content scrolls under it with a blur.
- Shortcuts has a **"Search shortcuts"** field at the top-right (rounded 10 pt, magnifier glyph).
- Sections: header 13 pt **bold** (x≈248), then grouped boxes (`boxColor`, radius ~12 pt, width ≈ 472 pt, 8–10 pt
  margins).
- Rows: min height 34 pt, 12 pt horizontal padding, hairline separators inset 12 pt. Title 13 pt. Optional
  description line in 11 pt `secondaryLabel` below the title.
- Trailing controls: **mini blue switches**, popup buttons showing the value plus a ⌃⌄ stepper glyph, grey
  "Options..." / "Choose..." / "Customize..." buttons.
- 24 pt vertical gap between sections.

**General:**
- App: Launch at login; Show menu bar icon.
- Capture: Hide desktop icons while capturing ("You can set a custom wallpaper to hide desktop icons in wallpaper
  settings." with a blue link).
- Sounds: Play sounds; Shutter sound [System Default].
- Export: Export location [📁 Desktop] [Choose...]. Description: "Set the default save location used when saving
  from the Quick Access Overlay, After Capture, and other Save actions across the app."
- **After Capture** ("Decide what should happen after taking a screenshot or recording a video."): a table with the
  columns **Action | Screenshot | Recording** and checkbox cells ("—" where not applicable). Rows:
  - Show Quick Access Overlay ✓✓
  - Copy file to clipboard
  - Save ✓–
  - Upload to Cloud & copy link
  - Open Annotate tool (–)
  - Pin to the screen (–)
  - Open Video Editor (– for screenshots)

**Shortcuts:**
- Groups have a glyph and a bold header:
  - ⚙ General: All-In-One, Toggle Desktop Icons, Open Capture History, Restore Last Capture.
  - 📷 Screenshots: Capture Area, Capture Previous Area, Capture Fullscreen, Capture Window, Self-Timer; then Capture
    Area & Copy to Clipboard / & Save / & Upload to Cloud / & Annotate / & Pin to the Screen / & Send to Raycast AI
    Chat.
  - Then Screen Recording, Scrolling Capture, OCR, Quick Access Overlay, Annotate (tool keys), Video Editor.
- Each row has a **recorder field** (≈ 156×28 pt, radius 6). Empty: grey fill with "Record shortcut" in secondary
  text. Set: white bezel with "⇧ ⌘ 4" in 13 pt semibold.
- Conflict messages: "Shortcut is reserved for macOS" and "Shortcut is used for another action" [S].

**Quick Access:**
- Appearance: Position on screen [Left]; Move to active screen ("Active screen is the screen where your cursor is
  pointing."); Overlay size [slider with 5 ticks].
- Behavior: Auto-close (toggle); Action [Save and Close] (disabled until auto-close is on); Interval [30 seconds].
- Second box: Close after dragging ("Hold ⌥ (option) to keep the item on Overlay after dragging."); Close after
  uploading; Save button behavior [Save to "Export location"] ("Press with ⌥ (option) to choose the destination.").

**Wallpaper:**
- Desktop: Wallpaper [Desktop wallpaper] ("Set a custom wallpaper used to hide desktop icons and as the background
  behind window screenshots.").
- Update wallpaper when switching Spaces.

**Screenshots:**
- Output: File format [PNG]; then a box with Convert to sRGB profile, Scale Retina screenshots to 1x, Add 1px
  border to all screenshots; then Background preset [None] ("Apply Background Tool preset to all screenshots. You
  can create presets in Annotate. Hold ⇧ Shift while capturing a screenshot to disable this option.").
- Capture: Self-Timer interval [5 Seconds]; Show cursor on screenshots ("This works in Fullscreen or Self-Timer
  modes only."); Freeze screen when taking a screenshot.
- Window Screenshots:
  - Background, with **two image tiles**: "With wallpaper" (selected, 2 pt blue ring, radius 8) and "Transparent".
    Description: "Hold ⇧ Shift while taking a screenshot to get a transparent background. You can customize the
    wallpaper in wallpaper settings."
  - Padding [slider]; Capture window shadow; [Reset Defaults] button below the box.
- Crosshair: Crosshair Mode [Disabled]; Show magnifier ("To enable magnifier, you must enable Crosshair Mode
  first.").
- PixelSnap promo card: "Need more precision?", "Automagically select objects to capture with PixelSnap.", blue
  "Learn more", with an illustration on the right.

**Screen Recording:**
- General: Show controls while recording; Remember last selection; Display recording time in menu bar; Dim screen
  while recording; Show countdown; "Do Not Disturb" while recording.
- Cursor: Show cursor; Highlight clicks [Options...].
- Keystrokes: Show keystrokes [Options...].
- Video: Frame rate [60 fps]; Max resolution [Original] ("Set maximum resolution to reduce file size and upload
  time."); Scale Retina videos to 1x.
- Audio: Record audio in mono; then a box with Record system audio ("Enable this option to record sound that comes
  from other applications.") and Audio tracks [Single track] ("Choose separate tracks to edit the microphone and
  system audio independently in video editing software.").
- GIF: Frame rate [15 fps]; Resolution [800 x auto (default)]; Optimize GIFs; Quality [Low ——●— High slider with
  ticks].

**Annotate:**
- Tools: Inverse arrow direction ("Press ⌥ (option) when drawing to invert the behavior."); Smooth drawing; Remember
  if background tool was opened; Draw shadow on objects; Automatically expand canvas ("Ensures all annotations fit
  by dynamically resizing canvas.").
- Window: Always on top; Show Dock icon.
- Accessibility: Show color names.

**Cloud:**
- Account box: avatar 40 pt, name, masked email; [Manage Account...] [Sign Out]. Then "Pro plan / Unlimited
  storage" with [Manage Plan...].
- Upload: Screenshot quality [Optimized for sharing] ("The "Optimized for sharing" option offers perfect balance
  between quality and loading time."); Ask for name & show advanced options ("…You can also access this feature by
  holding ⌥ (option) while clicking the upload button.").
- Clipboard: Copy to clipboard [CleanShot Cloud link]; Copy link when upload starts.
- Menu Bar: Show recently uploaded media.
- Notifications (below the fold).

**Advanced:**
- File Name: Ask for name after every capture; File name format [Customize...]; Add "@2x" suffix to Retina
  screenshots ("This option improves compatibility with displaying Retina screenshots in third-party apps.").
- Clipboard: Copy to clipboard [File & Image (default)] ("Adjust this option if you've encountered any issues with
  pasting from clipboard or clipboard managers.").
- Capture History: Keep history [3 days] ("You can restore old files with "Capture History" option from the menu
  bar.").
- Text Recognition: Language; Keep line breaks; Detect links.
- All-In-One: Remember last selection.
- Pinned Screenshots: Rounded corners; Shadow; Border.
- API: Allow URL scheme API ("Disable this option to prevent external apps from controlling CleanShot via URL scheme
  API." with a link).
- Reset All Warning Dialogs [S].

**File-name format sheet** (`NameTemplateWindow.nib`, white sheet, radius 18) [V settings14]:
- "Type text and drag elements to create a custom format:". A token field shows `CleanShot` %y - %m - %d at %H . %M
  . %S. Tokens are light-blue rounded chips (`#B8DCFF`, 4 pt radius).
- "Preview: CleanShot 2026-08-24 at 13.50.01".
- A grey box with a 2-column token legend: Year %y, Month (numeric) %m, Month (name) %n, Day %d, Day of week %w,
  Window title %t, App name %a | Hour %H, Minutes %M, Seconds %S, AM/PM %p, Random characters %r,
  Auto-increment %i.
- ☑ Remove illegal characters; ☐ Use UTC time zone; "Auto-increment next number:" field [S].
- Buttons: [Restore Defaults] … [Cancel] [OK (blue)].

Sheets dim the parent window with a white ~40% veil [V].

---

## 14. Onboarding (`Onboarding`, `ONView` + subclasses)

Onboarding is a single window (≈ 560×520 pt [U]) of horizontally sliding slides (`isAnimating`). Each slide is an
`ONView`:
- a centred content container (illustration or looping video with rounded corners, `OnboardingLoopingVideoView`
  `cornerRadius`)
- a title (22 pt bold) and body (13 pt secondary)
- a **bottom bar** with a secondary button on the left/centre and a blue primary on the right (`secondaryButton`,
  `primaryButton`) [S].

Slide order (class names), with exact strings where found [S]. Visuals are unverified except for the asset names:

1. `ONWelcomeView`: **"Welcome to CleanShot X"**, "Let's walk you through a quick configuration". Primary
   "Continue"/"Get Started" [U].
2. `ONSystemShortcutsView(Single)`: "Do you want to assign shortcuts" / "Use the same shortcut as macOS?" / "Do you
   want to assign system default shortcut to All-In-One mode?" Buttons "Use System Default Shortcuts", "Use old
   shortcut". Shows `onboardingShortcuts1–4`. Warns "It looks like you haven't disabled Screenshots shortcuts." with
   "Open System Settings".
3. `ONDefaultToolView`: "Set as default screenshot tool?"
4. `ONHideDesktopIconsView`: "Would you like to have your desktop icons hidden" (`onboardingDesktopIcons`).
5. `ONLaunchAtLoginView`: "Would you like to have CleanShot ready" … at login (`onboardingMenubar`).
6. `ONCloudView`: "Upload your screenshots to the Cloud", "Create a free account" / "Sign up for free"
   (`onboardingCloud`).
7. `ONStatisticsView`: "Share usage statistics?" / "Help us improve CleanShot by allowing us to collect completely
   anonymous usage data." (`onboardingStatistics`).
8. `ONPreferencesView`: **"Tweak your workflow"**, "You can adjust all the settings and set your own" …
   (`onboardingTweak`).
9. `ONFinishView`: **"CleanShot is ready to use!"** "You can access the app through the menu bar icon or by using
   the defined keyboard shortcuts." (`onboardingFinishIcon`). Newsletter and X quick tips: "Join our newsletter for
   exclusive tips, updates, and special offers." and "Follow us on X and be the first to know about new stuff!".

Also: "Allow Notifications..." prompt, a permission screen ("In order to continue working properly, CleanShot needs
Screen Recording permission." with "Open System Settings"), and the Studio Mode intro (`onboardingStudioMode`, §7.1)
[S].

Feature onboarding (`FeatureOnboarding`) appears inline the first time for OCR ("How to use the text recognition
tool?") and Scrolling Capture (`scrollingCaptureOnboarding*`) and "How to select an area?" [S].

**Changelog window** (`ChangelogView.nib`): "New in CleanShot X" with a web view, a toolbar, and a "Show changelog
after each update" checkbox [S].

---

## 15. Gaps / unverified summary

- Exact pixel sizes of overlays (AIO, recorder, QA card) are estimates (±15%). Calibrate against the macOS menu bar
  height in your own captures.
- Not seen in any public image: the OCR "Text has been copied" toast look, the onboarding slide visuals, the legacy
  4.x video trimmer, the pinned-screenshot right-click menu order, and the QA "newest" indicator.
- The meaning of the eye button on video QA cards (assumed Quick Look) is unverified.
- Area-selection size-badge placement and colours while dragging are inferred from a promo crop.
- The CleanShot X menu bar glyph is only approximately described. Ship a custom template image.
