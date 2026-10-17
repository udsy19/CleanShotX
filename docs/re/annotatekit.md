# AnnotateKit — reconstructed feature spec

Source of evidence: the CleanShot X 5.0.1 app bundle. Citations: `cd` = `classes-digest.md`, `sa` = `strings-app.txt`,
`ui` = `ui-sentences.txt`, `nib` = `nibs.txt`, `plist` = `Info.plist.txt`. Line numbers refer to those files.

Shotcraft re-implements the behaviour, not the code. Labels are short UI words only.

## 1. Object model (cd 54–300)

CleanShot keeps one `AnnotateSession` per editor window (cd `AnnotateSession`: `allObjects`, `newObject`,
`_selectedObject`, `history`, `pixelate`, `spotlight`, `counter`, per-property buttons, a CALayer tree
`frameLayer › shadowLayer › contentOuterLayer › contentInsetLayer › contentLayer › imageLayer › drawingInnerLayer`,
plus `realTodisplayTransform` / `displayToRealTransform`). Every annotation subclasses `ANDrawingObject`
(`layer`, `anchorPoints`, `selectionStrokeLayer`, `isDeleted`, `clickableArea`):

| CleanShot class | Base | Stored properties | Shotcraft `AnnotationKind` |
|---|---|---|---|
| ANRectangle | ANGenericRectangle | color, thickness | `.rectangle` |
| ANFilledRectangle | ANGenericRectangle | color | `.filledRectangle` |
| ANEllipse | ANGenericRectangle | color, thickness | `.ellipse` |
| ANLine | ANGenericLine | color, thickness | `.line` |
| ANArrow | ANGenericLine | controlPoint, controlAnchorPoint, arrowStyle, inverseDirection | `.arrow` |
| ANText | ANDrawingObject | textStyle, fontSize, color, width, text, position | `.text` |
| ANDraw | ANDrawingObject | points, smoothing, pathSmoothed, isDrawingStraightLine | `.pen` |
| ANHighlighter | ANDraw | multiplyBlendingMode, shouldSnapToText | `.highlighter` |
| ANPixelate | ANInvisibleRectangle | (style/intensity live in ANPixelateController) | `.pixelate` |
| ANSpotlight | ANInvisibleRectangle | shape | `.spotlight` |
| ANCounter | ANDrawingObject | color, thickness, position, style, number | `.counter` |
| ANImageObject | ANInvisibleRectangle | image, imageLayer | `.image` |

`ANGenericRectangle` is defined by `startPoint/endPoint` with four corner `ANAnchorPoint`s;
`ANGenericLine` by `startPoint/endPoint` with two anchors. Shotcraft uses one flat `Annotation` value type
(`start`, `end`, `control`, `points`, style fields) so the whole document is a value and undo is a snapshot.

`ANShadow` (radius, color, offset) + Settings `_drawShadow` (cd AnnotateSettings) → per-object `shadow` flag
seeded from `.annotateDrawShadow`; the toolbar toggle flips the default and the selection.

## 2. Tools and shortcuts

Tool identifiers recovered from `sa` 4199–4306 (`annotateArrowTool`, `annotateRectangleTool`,
`annotateFilledRectangleTool`, `annotateEllipseTool`, `annotateLineTool`, `annotateTextTool`, `annotateDrawTool`,
`annotateDrawHighlightTool`, `annotatePixelateTool`, `annotateCounterTool`, `annotateMoveTool`, `annotateFrameTool`
= background), titles from `ui` 262/393/421 ("Crop & Resize Tool", "Filled Rectangle Tool", "Highlighter Tool").

| Tool | Key | Options (evidence) |
|---|---|---|
| Move / select | V | — (`annotateMoveTool`) |
| Crop & Resize | K | ratio popup, W×H fields, swap, snapping, Resize popover (cd ANCropController, ANResizeControlViewController) |
| Rectangle | R | color, thickness |
| Filled Rectangle | F | color |
| Ellipse | E | color, thickness |
| Line | L | color, thickness |
| Arrow | A | style: standard / curved / double / fancy / slim (`annotateArrowStyle*` sa 4205–4212; generators `OriginalArrowGenerator`, `FancyArrowGenerator`, `SlimArrowGenerator(controlPoint, doubleHeaded)` cd 1–46) |
| Text | T | style: standard / outline / box / rounded / rounded box / monospaced / monospaced box (`annotateTextStyle*` sa 4291–4298); font size (`annotateLastTextSize`); emoji (ANTextEmojiButton) |
| Pen (draw) | D | color, thickness; smoothing per `_smoothDrawing`; ⇧ draws a straight segment (`isDrawingStraightLine`) |
| Highlighter | M | shape: freehand / rectangle (`annotate_highlight_shape`, `annotateLastHighlightShape`), opacity (`annotateLastHighlightOpacity`), multiply blending (`multiplyBlendingMode`) |
| Pixelate | P | style: pixelate / blur / secure blur / black out (`annotatePixelateStyle*` sa 4270–4277), intensity slider (`annotatePixelateIntensity`) |
| Spotlight | H | shape rect/ellipse (ANSpotlightShapeButton), opacity slider (`spotlightOpacitySlider`) |
| Counter | C | style numbers / letters / roman (sa 14092, 16651), "Starting number:" (sa 19528), size (ANCounterSettingsButton `sizeChangedWithSender:`) |
| Background | B | sidebar (§5) |

Keys follow CleanShot X 5.0 (`docs/re/ui-reference.md` §5). Toolbar, left → right: Crop, Add image (⇧⌘I new
screenshot, ⌘I from file, paste), Background chips · segmented tools Move, Rectangle, Filled Rectangle, Ellipse, Line,
Arrow, Text, Pixelate, Spotlight, Counter, Draw, Highlighter · colour well (palette popover), tool-style popover
(per-tool options), draw lock (off = back to Move after each object) · Save / Save as… (per "Save button behavior"),
Done (⌘S, ⌘↩). In crop mode the tool group becomes the crop bar and Save/Done become Cancel/Crop. Bottom bar: zoom
popup, "Drag me", Share, Pin, Copy (⌥ keeps the editor open), Upload. Save As / Save Project / Open / Print live in
the canvas context menu and on ⇧⌘S / ⌥⌘S / ⌘O / ⌘P.

Thickness shortcuts `annotateIncreaseThickness` / `annotateDecreaseThickness` → `]`/`[` (without ⌘).
Modifiers: ⇧ constrains (45° for lines/arrows, square/circle for shapes, aspect for image), ⌥ draws from center.
Each tool remembers its own style (`annotateLastArrowStyle`, `annotateLastPixelateStyle`, `annotateLastCounterStyle`,
`annotateLastTextSize` …); Shotcraft stores a `[tool: ToolStyle]` map under `annotate.toolStyles`.

Object commands (`ui` 233, 313; `sa` 4221/4238): Copy Object to Clipboard (⌘C with a selection, otherwise the
flattened screenshot — `annotateCopyScreenshot`), Duplicate Object (⌘D), paste (⌘V; pasted images become image
objects), delete (⌫), select all (⌘A), arrange (⌘] / ⌘[ forward/backward, ⌥⌘ for front/back), arrow-key nudge
(⇧ = 10 pt), double-click text to edit, Esc deselects / cancels.

Image objects: `addNewImageObjectFromFile`, `addNewImageObjectFromClipboard`, `takeNewScreenshot` (cd Annotate);
labels "Add Screenshot From File", "Add New Screenshot", "Paste From Clipboard" (ui 4–5, 617).

## 3. Canvas behaviours

* Zoom: `ANZoomController` (zoom, magnification events, `userDidSetZoom`), `ANZoomButton` popup → pinch,
  ⌘+ / ⌘− / ⌘0 (fit) / ⌘1 (100 %), zoom popup in the bottom bar.
* Pan: `ANScrollView.scrollWheel:`; `Annotate.otherMouseDragged:` and space-drag (`spaceIsDown` in ACController).
* Snapping: `ANSnappingController(lineLayerX, lineLayerY, redColor, blueColor, mainImageSize)` → guide lines when an
  object's edges/centre align with the canvas centre/edges (red) or another object (blue).
* Checkerboard behind transparency: `CheckerboardView`, `BackgroundLayer(drawsTransparentCheckerboard)`.
* Auto-expand: "Ensures all annotations fit by dynamically resizing canvas." (ui 319, `_autoExpandCanvas`).
* Dock icon / always-on-top: `_showDockIcon`, `_alwaysOnTop` (cd AnnotateSettings).
* Drop zone: `ANDropZoneView` with `annotateDropArrow{Top,Left,Right,Bottom}` — files dropped on the canvas are added
  as image objects.

## 4. Crop & resize

`ANCropController` (ratioPopupButton, widthRatioTextField/heightRatioTextField, `swapRatio`, `freeformMenuItem`,
`customRatioMenuItem`, `snappingDidSetWithSender:`, `reset`, `doneButtonPressed`) and `ANCropAreaController`
(curtain, grid, border layers). `CropSnappingController(screenshot, bitmap, scale)` snaps the crop to image edges.
Setting `.annotateSnapCrop`. Resize popover nib (nib 37–70): "Width:", "Height:", unit popup "pixels"/"percent",
proportion lock, "Flatten Annotations" switch with "(Can't be undone)", Cancel / Resize; warning
"This action will flatten all annotations, making them uneditable." (ui 1031).
Shotcraft: crop is a non-destructive `cropRect` in document space (Return applies, Esc cancels); Resize scales the
base image and all objects (optionally flattening first).

## 5. Background tool

`ANBackgroundSettings` (cd 89): `paddingSlider`, `cornersSlider`, `shadowSlider`, `insetSlider`,
`alignmentSelector`, `autoBalanceButton`, `ratioPopupButton`, `presetsControl`, `moreButton`/`showsFullGradientList`.
`ANCanvasController` (cd 114): `padding`, `inset`, `balanceInsets`, `insetColor`, `background`,
`cornerRoundnessPercent`, `shadowIntensity`, `alignment`, `ratio`. `ANBackgroundManager`: `gradients`, `colors`,
`customWallpapers`, `desktopBackground`. `ANBackground`: `type`, `color`, `image`, `fileReference`.
`ANPresetControl`: add / save / delete / set-default preset (`annotatePresetNew/Save/Trash`).
Remembering the sidebar: "Remember if background tool was opened" (ui 660, `.annotateRememberBackgroundTool`).

Shotcraft `BackgroundSettings`: fill `none | color | gradient(id) | desktop wallpaper | image file`;
padding (pt), inset (pt, colour sampled from the image corner), auto-balance (centre the opaque part of the image —
window screenshots with transparent shadow margins), corner radius (pt), shadow (0–1), 9-point alignment,
aspect ratio `auto, 1:1, 4:3, 3:2, 16:10, 16:9, 9:16, custom`. 20 original gradients (10 shown, "Show more"),
wallpapers (desktop + recent custom images in `annotate.customWallpapers`), blurred fills (blurred wallpaper, frosted
light, frosted grey), plain colours (8 saturated + transparent, 8 pastel + custom wheel).
Presets live in `annotate.backgroundPresets`; the last settings in `annotate.lastBackground`; the default preset
(auto-applied to newly opened screenshots) in `annotate.defaultBackgroundPreset`.

## 6. Colour palette

`ANColorPalette(defaultColors, defaultColorsNames, showsAlpha)`, custom colours (`annotateCustomColors`,
`annotate_custom_colors_count`), `ANColorPicker` with pipette (`pipetteClicked`), `_showColorNames`.
Shotcraft: popover with two columns — ten default colours (names shown per `.annotateShowColorNames`) and ten
"My Colors" slots (`annotate.customColors`; hover ✕ deletes, drag reorders, empty slot adds the current colour) — plus
a colour-wheel button (NSColorPanel) and an expand chevron (`annotate.paletteExpanded`) that reveals a
saturation/brightness square, hue and alpha sliders, hex field, eyedropper (`NSColorSampler`), R/G/B/Alpha fields and
"Add to My Colors".

## 7. Saving, exporting

`Annotate` selectors (cd 310): `saveAsClicked`, `doneClicked`, `saveAndCloseWithDestination:`, `uploadAndClose`,
`copyToClipboardWithClose:`, `pinAndClose`, `printImage`, `savePanelFormatButton`, `windowShouldClose:`;
analytics `annotate_save_{done,clipboard,cloud,pin,dragme,savepanel,sharesheet}` (sa 4186–4192).
`ANDragButton` (drag-me), `ANShareButton` (NSSharingServicePicker), `ImagePrinter` + `CSPrintAccessoryViewController`
+ `MultiPageImageView(fitToSinglePage)` — "Scale image to fit on one page" (ui 703).
Close prompts: "Do you want to save the changes you made to the screenshot?" / "…made to this project?" (ui 294–296).

Shotcraft behaviour:
* **Done** (⌘S / ⌘↩): flatten → write to `media.url` in its format (captures/opened files); a clipboard session
  writes a new file and hands it to `MediaPipeline.ingest(…, [.showQuickAccess])`. Also writes the project to
  `AppPaths.projects/<media-id>.shotcraft`, sets `media.projectURL`, `media.notifyChanged()`, closes.
* **Save**: `.annotateSaveBehavior` — export location (unique name) or save panel. **Save As…** panel with a format
  popup (PNG/JPG/HEIC/TIFF/Shotcraft Project). **Save Project…** writes a `.shotcraft` document.
* **Copy** (button) copies the flattened image and closes; ⌘C copies without closing.
* **Upload / Pin**: commit, then `Services.upload.upload` / `Services.pin.pin`, close.
* **Share**, **Drag me** (temp file), **Print** (fit to one page option).

## 8. Document format

CleanShot: `Document: NSDocument`, `AnnotateDocument(metadata, serializableDocument, previewBitmap,
thumbnailBitmap, projectURL)`, UTI `com.cleanshot.document` / extension `cleanshot` (plist 35–110), "CleanShot
Project" (sa 6112), `AnnotateController(projectsHistory, annotates)`, errors "An error occurred while opening/saving
the project" (sa 3974/3977).

Shotcraft `.shotcraft` (UTI `com.udsy.shotcraft.document`) is a single UTF-8 JSON file:

```json
{ "format": "com.udsy.shotcraft.document", "version": 1,
  "createdAt": "...", "modifiedAt": "...", "sourcePath": "/…/Screenshot.png",
  "image": { "scale": 2, "png": "<base64>" },
  "cropRect": [[x, y], [w, h]] | null,
  "background": { "fill": {...}, "padding": 64, ... },
  "spotlightOpacity": 0.55, "counterStart": 1,
  "objects": [ { "id": "...", "kind": "arrow", "start": [x,y], "end": [x,y], "color": {...}, ... } ] }
```

Coordinates are image points (pixels ÷ scale), y-down, origin at the image's top-left; objects may lie outside the
image (expanded canvas). Recent projects: `annotate.recentProjects` (newest first, max 15).

## 9. Rendering

One renderer (`AnnotateRenderer`) draws background → shadow → rounded frame (inset fill) → base image →
pixelate effects (CoreImage, cached per style/intensity) → spotlight dimming (even-odd union of holes) →
annotations in z-order (highlighter with multiply). The canvas view calls the same renderer with the view's
transform; export renders at `image.scale` so a Retina capture keeps its full pixel resolution.
