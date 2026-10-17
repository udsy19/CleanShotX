# TextKit — Capture Text (OCR) + Scrolling Capture

Reconstructed behaviour of CleanShot X 5.0.1's text-recognition and scrolling-capture features and how
Shotcraft's `TextKit` reimplements them. Evidence references: `docs/re/raw/classes-digest.md` (CD),
`docs/re/raw/strings-app.txt` (SA), `docs/re/raw/ui-sentences.txt` (UI), and `nm -u` of the arm64 slice (NM).

## 1. Evidence summary

### OCR
| Evidence | Source | Inference |
|---|---|---|
| `OCR` class, ivars `supportedLanguages, didWarmUp` | CD:865 | A singleton recogniser that caches the supported-language list and warms Vision up at launch. |
| `VNRecognizeTextRequest`, `VNRecognizedTextObservation`, `VNRecognizedText`, `topCandidates:` | NM, SA:21743 | Apple Vision text recognition, best candidate per line. |
| `setRecognitionLevel:`, `setUsesLanguageCorrection:` | SA:18358, SA:18649 | `.accurate` level with language correction. |
| `supportedRecognitionLanguagesAndReturnError:` | SA:19837 | Language list comes from Vision (fed to the Preferences language picker). |
| `_automaticallyDetectLanguage`, "Automatically Detect Language" | SA:267, UI:135 | Preference: automatic language detection vs. a manual language list. |
| `_keepLineBreaks`, "Keep line breaks", "Capture Text With/Without Line Breaks" | SA:601, UI:466, UI:187-188 | Preference + two menu/URL variants that override it. |
| `VNDetectBarcodesRequest`, `VNBarcodeObservation`, `VNBarcodeSymbologyQR`; "…and even QR codes." | NM, SA:10745 | Barcode/QR payloads are recognised alongside text. |
| `VNDetectTextRectanglesRequest` | NM | Used for the onboarding/highlight animation (not needed for the copy flow). |
| `ocrDetectURLs`, "Do you want to open this link?", "Open Link in Browser", "Never open links" | SA:14171, UI:292/600/524 | When the result is a link, optionally ask to open it; one button disables the preference. |
| "No text detected", "Text has been copied" | UI:565, UI:793 | HUD messages for the two outcomes. |
| `OCROnboarding`, `OCRONGuide`, `onboardingOCRDisplayed`, "How to use the text recognition tool?" | CD:867-869, SA:14239, UI:424 | First-use onboarding (owned by PreferencesKit onboarding in Shotcraft). |
| Language display names "Chinese (Simplified)", "Norwegian (Bokmål)" | UI:191, UI:577 | Codes are shown with localized names; Vision codes are BCP-47 (`en-US`, `zh-Hans`, `nb-NO`). |

### Scrolling capture
| Evidence | Source | Inference |
|---|---|---|
| `ScrollingGrabber` ivars `horizontalMode, shotA, shotB, lastComparedShot, lastMatch, mergedImage, headerHeight, heightDiff, matchNotFoundCount, timer, captureRect, grabsRetinaScreenshot, previewLayerSize, windowID, counter`; sel `captureAndCompare` | CD:1103 | Timer-driven grab of the area; each shot compared to the previous one (A/B); a fixed sticky *header* height is tracked; the offset (`heightDiff`) appends new rows to `mergedImage`; repeated "match not found" is counted. |
| Subclasses `ClassicScrollingGrabber`, `VisionScrollingGrabber`, `AutomaticScrollingGrabber (matches, finalMatch, isPaused)` | CD:338/400/1191 | Two matchers (pixel-row "classic" and Vision registration) plus an auto-scroll driver that stops on a final match. |
| `VNTranslationalImageRegistrationRequest`, `VNImageTranslationAlignmentObservation`, `VNSequenceRequestHandler` | NM | Vision's translational registration gives the frame-to-frame shift. |
| `CGEventCreateScrollWheelEvent2`, `CGEventPost`; `autoScrollSpeed`, `autoScrollTimer`, `scrollingCaptureAutoScroll(Horizontal)`; "Auto-Scroll needs …" | NM, SA:4811/4883/17073 | Auto-scroll posts synthetic scroll-wheel events; needs Accessibility permission. |
| `SGOverlay` ivars `controlsView, controlsChildWindow, autoScrollChildWindow, horizontalAutoScrollChildWindow, previewView, slowDownAlert, errorAlert, pausedAlert, veryLargeAlert, horizontalMatches, verticalMatches, isDetecting`; sels `rectangleChanged, horizontalAutoScrollClicked, verticalAutoScrollClicked, performKeyEquivalent:` | CD:1074 | Overlay = border + control child window + auto-scroll buttons + live preview + transient alerts; orientation is *detected* by running vertical and horizontal matchers in parallel until one matches; Esc via key equivalents. |
| `SGControlsView` (`isStartButtonVisible, doneButton`; `startClicked helpClicked cancelClicked doneClicked`) | CD:1071 | Control bar: Start → Done, Help, Cancel. |
| `SGAlert : FSInfoLabel` (`hideTimer, shaking`), `PauseSGAlert`, `PermanentWarningSGAlert` | CD:962-1068 | Pill-shaped info labels that auto-hide, can shake; a pause alert; a permanent warning. |
| "Move cursor here to start scrolling", "Slowly scroll down the content", "Scroll Vertically or Horizontally", "Please slow down...", "Screenshot is very large" | UI:510/754/715/631, SA:55 | Hint texts for each state. |
| "Currently, the following conditions may break the scrolling capture:" + "When selected area contains animations or videos." / "…not scrolling entirely vertically or horizontally." / "…scrolling too fast." / "…start scrolling up." ; "Only scrollable content should be selected…" | SA:7066, SA:56-60, SA:14299 | Help popover contents (rephrased in Shotcraft). |
| `onboardingScrollingCaptureDisplayed`, `SCONArea/SCONScroll/SCONScrollOrientation/SCONTroubleshooting` | SA:14240, CD:1057-1065 | First-use onboarding pages (area → scroll → orientation → troubleshooting). |

## 2. Capture Text flow (`TextServicing.captureText(keepLineBreaks:)`)
1. Ensure Screen Recording permission. `Services.capture.selectArea(purpose: .text, allowsWindowSelection: true)`.
2. Window click → `ScreenCapturer.capture(windowID:shadow:false)` (works even if covered); drag → `capture(globalRect:)`, cursor hidden.
3. Off the main thread: `VNRecognizeTextRequest` (`.accurate`, `usesLanguageCorrection`, `automaticallyDetectsLanguage`
   when `ocrLanguageMode == .automatic`, else `recognitionLanguages = ocrLanguages` normalised to Vision's BCP-47 codes)
   then `VNDetectBarcodesRequest`. Small captures (< 0.4 MP) are upscaled 2× first — Vision misses tiny glyphs.
4. Layout → reading order (see §3), join per `keepLineBreaks ?? ocrKeepLineBreaks`; barcode payloads not already
   present in the text are appended on their own lines.
5. Empty → HUD "No text detected". Otherwise `Clipboard.copy(text:)`, `Sound.play(.textCopied)`, HUD "Text has been copied".
6. If `ocrOpenLinks` and the whole result is one http(s) URL → alert "Do you want to open this link?" with
   *Open Link in Browser* / *Cancel* / *Never open links* (turns the preference off).

## 3. Reading order and joining (`TextAssembler`, pure)
* Boxes converted to top-left pixel space. Median line height `h` is the unit for all thresholds.
* **Columns**: x-ranges of "narrow" lines (< 60 % of the content width) are merged with tolerance `max(h, 2 % width)`;
  ≥ 2 resulting intervals with ≥ 2 lines each and a prose-like fill (median line width ≥ 45 % of its column) are columns.
  Otherwise (tables, label/value forms) everything is one column so rows read left→right.
* Wide lines (headings spanning columns) split the page into bands; within a band columns are emitted left→right.
* **Rows**: lines whose vertical overlap ≥ 50 % of the shorter height are one row, ordered by x and space-joined.
* **Paragraphs**: a vertical gap > 1.5 `h` between rows starts a new paragraph (blank line when keeping line breaks).
* **Joining** without line breaks: `word-` + lowercase continuation → `word` + continuation (de-hyphenation; also
  U+2010 / soft hyphen); a CJK character (Han, kana, CJK punctuation, full-width forms) on either side → no space;
  otherwise a single space. With line breaks rows are joined with `\n`.

## 4. Scrolling Capture (`startScrollingCapture`)
### UI (SGOverlay equivalents)
* **Frame window**: full-screen click-through window dimming everything but the area, with a border just outside it.
  All our windows belong to our process and are therefore excluded by `ScreenCapturer`.
* **Controls panel** (below the area, else above, else inside): orientation popup (Auto / Vertical / Horizontal,
  persisted as `textkit.scrollingOrientation`), *Auto-Scroll* toggle, *Start Capture* → *Done*, frame counter,
  Help popover (rephrased troubleshooting list), *Cancel*. Esc cancels, Return starts/finishes (local monitor, plus a
  global monitor which works when Accessibility is granted).
* **Preview panel** beside the area (right, else left; below/above for horizontal): live stitched image anchored to the
  newest content + pixel dimensions.
* **Hint pill** centred in the area: "Move cursor here to start scrolling" (cursor outside), "Slowly scroll down the
  content" / "Slowly scroll right" / "Scroll Vertically or Horizontally" (until the first match), "Please slow down..."
  (shakes; no overlap found), "Scroll down to continue" (pause after scrolling back), "Screenshot is very large"
  (permanent, capture stops growing at 30 000 px).

### Frame loop
* Manual: a 10 Hz timer grabs `ScreenCapturer.capture(rect:on:showsCursor:false)`; a grab is skipped while the
  previous one is still being captured/processed, so the effective rate adapts to the machine (8–10 fps typical).
* Auto-scroll: needs Accessibility (`Permissions.requestAccessibility()` otherwise). Cursor is parked at the area centre;
  each step posts pixel-unit `CGEvent` scroll-wheel events (≈ 35 % of the area, chunked ≤ 60 px), waits 0.35 s for
  smooth-scrolling to settle, grabs and compares. Three consecutive unchanged frames = end of content → auto Done.
  "No overlap" makes it scroll back by the same step and halve the step.

### Stitching (`ScrollStitcher`, `OffsetDetector`, pure)
* Each frame → `ScrollFrame`: 8-bit grayscale, oriented so "rows" run along the scroll axis (transposed for
  horizontal), per-row FNV-1a hash, "informative" flag (contrast > 16) and a 96-column block-mean profile.
* **Static bands**: leading/trailing rows whose hashes are equal at the same position in A and B are sticky
  header/footer (or blank margins) and excluded from matching. The trailing size is fixed at the first match
  (`headerHeight` analogue); the leading one is re-measured per pair.
* **Offset candidates**: (1) votes `yA − yB` from informative rows that are unique in both frames' bands; (2) if no
  candidate verifies: a coarse SAD search over vertically-downsampled profiles (≈ 200 rows) with early abandoning,
  refined ±s at full resolution; (3) the Vision `VNTranslationalImageRegistrationRequest` shift as a hint (both signs,
  refined ±3). Each candidate is verified by the mean absolute profile difference over the overlap (overlap ≥
  max(12, band/10)). d = 0 → unchanged; d < 0 → user scrolled back (paused); no verified candidate → "slow down".
* **Canvas**: first frame up to its footer, then for each accepted frame the `d` rows just above the footer, finally the
  last frame's footer. Strips are copied into their own bitmaps so frames are not retained. Length is capped at
  30 000 px. Comparison is always against the last *accepted* frame, so scrolling back up and down again recovers.
* Orientation "Auto": vertical and horizontal stitchers run side by side until one produces a match; the other is
  dropped (CleanShot's `verticalMatches/horizontalMatches/isDetecting`).
* Done → `MediaPipeline.didCaptureImage(stitched, scale: screen.backingScaleFactor, mode: .scrolling, actions: options.actions)`.

## 5. Not reproduced
* Onboarding pages (OCR/scrolling) — owned by PreferencesKit's onboarding.
* Resizing the area after selection (`rectangleChanged`) — re-select instead.
