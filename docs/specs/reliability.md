# Reliability & data-loss audit (FMEA)

The question behind every row: *the user has made something — a recording, an annotated screenshot, an upload —
and something goes wrong. Is it gone?* Each row names the failure, what must happen, what the code did before the
audit, what changed, and which self-test (`swift build --product SuperScreenshotSelfTest &&
.build/debug/SuperScreenshotSelfTest`) pins it down. Tests run only in temporary folders with synthetic frames;
nothing captures the real screen or microphone.

Conventions in the *fix* column: **new** = added by this audit; **ok** = already correct, verified; **accepted** =
known residual risk, with the reason.

## 1. Recording (highest risk)

Mechanism (new): every recording writer (`CaptureEngine`, Studio `ScreenRecorder`) sets
`movieFragmentInterval = 2 s` and writes into `~/Library/Application Support/SuperScreenshot/InProgress/` next
to a JSON manifest (`RecordingRecovery.Manifest`: kind, intended name, file, start time, writing pid, pixel size,
scale). With movie fragments the file on disk is playable up to the last fragment at any moment, so at most ~2 s
are lost however the process dies. `RecordingRecovery.recoverAll()` runs at launch: manifests whose process is
gone are salvaged (passthrough re-mux into `Recordings/<name> (recovered).mp4|mov`; if the re-mux fails the raw
file is moved there, since it already plays), the user sees "Recovered recording from <date>", and the file goes
through the normal after-recording flow (Quick Access, save, upload…). On a clean stop the file is moved to
`Recordings/` and the manifest removed; on delete/restart both are removed.

| area | scenario | expected | before | fix | test |
|---|---|---|---|---|---|
| Recording | App crash / force quit / power loss / kill by TCC while recording | Everything up to a few seconds before is kept and offered at next launch | `moov` written only at `finishWriting`: the whole file was unreadable, and the engine deleted it on any failure | **new** fragments + in-progress manifest + launch salvage (see above) | `Recovery.salvageAbandonedWriter` (abandons a fragmented mp4 and mov writer without finishing, salvages 4 of 5 s, re-reads the re-muxed file), `Recovery.pending`, `Recovery.bookkeeping` |
| Recording | Writer fails mid-recording (disk full, stream died, display unplugged) | Keep what reached the disk, tell the user | `finish()` cancelled the writer and deleted the file → nothing left | **new** a failed writer is not cancelled; `RecordingSession.stop` salvages the file and shows "Recording stopped unexpectedly… the m:ss recorded before that was kept" | `Recovery.salvageAbandonedWriter` (same path: file without `finishWriting`) |
| Recording | Disk nearly full | Stop before the disk is full, keep the file | 5-second disk check stops at < 500 MB | ok; plus the salvage path above if the writer fails first | `RecordingKit.clockAndKeys` (`isDiskNearlyFull`) |
| Recording | ⌘Q / update-triggered quit during a recording or while a stopped recording is still finalizing | Recording finalized before the process exits | `applicationShouldTerminate` only checked uploads; the process exited with the writer open (file lost) | **new** quit order: unsaved annotations → uploads → stop recording and `.terminateLater` until `RecordingServicing.isFinalizing`/Studio `isRecording` clear (30 s cap); the update swap helper is only spawned in `applicationWillTerminate`, i.e. afterwards | review (`AppDelegate.applicationShouldTerminate`) |
| Recording | Auto-update idle swap while finalizing / converting a GIF | Never swaps | Gate checked `isRecording` only (false once stopped) | **new** gate also checks `isFinalizing`; GIF popup is a window, which already blocks | `UpdateKit` gate tests (`UpdateApplyGate`) |
| Recording | Sleep / lid close | Recording stops cleanly, file kept | Video: `willSleep` → stop. Studio: no observer (stream error → stop, later) | **new** Studio also stops on `willSleep`; with fragments an interrupted finalize is still recoverable at next launch | — |
| Recording | Display disconnected | Stop with message, file kept | `didChangeScreenParameters` → stop(failure:) | ok (now keeps the file even if the writer failed) | — |
| Recording | Stop pressed twice / stop while starting | One finalize | `isFinishing` guard; `requestStop` during start | ok | — |
| Recording | Microphone unplugged mid-recording | Recording continues, user told | Silent audio, no message | **new** `AVCaptureDevice.wasDisconnected` → HUD "Microphone disconnected — recording continues without it" | — |
| Recording | Mic / Screen Recording permission revoked mid-recording | Not lose the recording | macOS kills the process on revocation | covered by crash recovery | `Recovery.*` |
| Recording | Recording longer than hours | No size limit, no memory growth | MP4/MOV 64-bit offsets; per-track `lastPTS` only | ok; **accepted**: a FAT32 export folder caps files at 4 GB (the move fails and the file stays in `Recordings/`, see `RecordingRecovery.complete`) | `Recovery.bookkeeping` (failed move keeps the file) |
| Recording | GIF conversion fails or app crashes during conversion | Keep the recording | Source video deleted on any error | **new** failure → "Couldn't create the GIF… kept as a video"; the source stays in-progress until the GIF is delivered, so a crash salvages it as video | — |
| Recording | GIF of a long recording (memory) | Flat memory | Streams one frame at a time | ok | `RecordingKit.gifConvertStreams` |
| Recording | Camera bubble device unplugged | Recording continues | Preview goes black, burned into the video | **accepted** (visible, not data loss) | — |
| Studio | Crash / force quit during a Studio recording | Keep the screen video | Work dir in `/tmp`, non-fragmented `screen.mov` → lost | **new** package written in the in-progress folder with fragments; salvaged as a plain video (cursor/click events are in memory until stop and are lost — **accepted**) | `Recovery.*` (package-shaped manifest) |
| Studio | Package write fails at stop (events/project JSON, move to Projects) | Keep the screen video | Work dir deleted | **new** salvage as a plain video with message | — |
| Studio | Project edits lost on crash | Autosave ≤ 1 s, recovered on open | `autosave.json` serialized on an io queue; `readProject` prefers it | ok | `Studio.PackageRecovery` |
| Studio | Corrupt `autosave.json` / `project.json`, missing `screen.mov` | Fall back / clear error | ok | ok | `Studio.PackageRecovery` |

### Why movie fragments (trade-off)

Fragmented MP4/MOV is QuickTime's own format and plays in QuickTime Player, Finder, Safari/Chrome/Firefox and
ffmpeg-based tools; seeking is marginally slower and the layout is not "fast start". The alternative (re-muxing
every finished recording into a flat file) would double disk use and finalize time for hour-long recordings,
so finished files stay fragmented. Exports from the video editor are flat.

## 2. Exports and editors

| area | scenario | expected | before | fix | test |
|---|---|---|---|---|---|
| Video editor | Export to the source URL | Temp file, swap on success | `removeItem(output)` first → source destroyed on failure (the editor never passed it; the API was unsafe) | **new** temp + `replaceItemAt`; partial removed on any error | `RecordingKit.exportOverSource` |
| Video editor | Cancel mid-way / before the export starts | Partial gone, source intact, re-export works | Cancel while the composition was loading crashed (`cancelExport` before `exportAsynchronously`) | **new** `PassthroughGate` orders start/cancel | `RecordingKit.exportCancel` |
| Video / GIF | Unwritable folder, a folder as destination, missing or empty source | Clear error, nothing left | A folder destination was silently deleted; missing source gave a raw AVFoundation error | **new** folder refused; "moved or deleted" message | `RecordingKit.exportFailure` |
| Video editor | Close during export | Prompt, cancel cleanly | Beep + refuse | **new** confirm → cancel + close; nothing reloads into a closed window | review |
| Video editor | Close with uncommitted trim | Source untouched | Save / Cancel / Don't Save; replace only after success | ok | review |
| Video editor | Source deleted while open | Clear error, no crash | Replace would throw | **new** export moved into place if the original vanished | `RecordingKit.exportFailure` |
| Studio export | Temp-then-move, cancel, unwritable, folder | Partial never visible in `Recordings/` | Wrote straight into `Recordings/` | **new** temp + move; fast-fail with plain message | `Studio.ExportLifecycle` |
| Studio GIF export | Flat memory | | `CGImageDestination` held every frame until finalize | **new** `StreamingGIFWriter` moved to Core, used by both exporters | `Studio.ExportLifecycle` |
| Timelines | 3-hour recording thumbnails | Bounded | Video editor fixed 14; Studio lazy visible tiles, 500-image cap | ok | review |
| Renderers | Per-frame allocations | Pooled | Pump loops lacked `autoreleasepool` | **new** per-sample `autoreleasepool` | — |
| GIF editor | Whole GIF in memory, re-encode on main thread | | | **accepted** (slow, not lossy) | — |

## 3. Annotate

Mechanism (new): `AnnotateRecovery` writes the full `.superscreenshot` document (image + objects + source link)
to `~/Library/Application Support/SuperScreenshot/Recovery/<editor id>.superscreenshot` one second after every
change and on window deactivate; encoding runs off the main thread from an immutable snapshot on a serial queue, so
a late write can never resurrect a file after the editor closed. The copy is deleted on save, Done, Don't Save or
a clean close. At launch `AnnotateKitModule.recoverUnsavedDocuments()` offers "Reopen / Delete" and reopens them
as dirty editors (so the copy keeps refreshing).

| area | scenario | expected | before | fix | test |
|---|---|---|---|---|---|
| Annotate | Crash / force quit / power loss with unsaved edits | Edits survive | All in memory | **new** recovery copies (above) | `Annotate.Recovery` |
| Annotate | ⌘Q with dirty editors | Save / Don't Save / Cancel | Silent loss (⌘Q bypasses `windowShouldClose`) | **new** `AnnotateKitModule.confirmTerminationIfUnsaved()` first in the quit order | — (UI) |
| Annotate | Close window with unsaved changes | Prompt | ok | ok | — |
| Annotate | Save over an existing file | Atomic | `Data.write(.atomic)` / `ImageTools.write` atomic | ok | `Annotate.AtomicSave` (chmod 0500 fault injection) |
| Annotate | Unwritable destination | Plain error, editor stays open and dirty | ok (`commitToMedia` returns nil → no close) | ok | — |
| Annotate | Project session Save | Dirty until the project is written | `save()` ignored `writeProject`'s result and closed | **new** guard on the result | — |
| Annotate | Undo stack memory with huge images | Shared references | `CGImage` + `Data` shared across snapshots; only Resize/flatten allocates | **accepted** | — |

## 4. Uploads

| area | scenario | expected | before | fix | test |
|---|---|---|---|---|---|
| Upload | Network loss mid-upload | Clean failure, bounded retry, queue continues, user can retry | 2 retries on a narrow error set; alert had no retry | **new** `UploadRetryPolicy` 3× (1/3/9 s) on network `URLError`s + 429/5xx; "Try Again" re-queues | `retryPolicy`, `transport.retriesTransientThenSucceeds`, `givesUpAfterRetries`, `cancelDuringBackoff` |
| Upload | Captive portal | Never reported as success | Redirects followed → a login page could pass as 200 | **new** only 307/308 followed; S3 HTML bodies rejected | `transport.redirectIsNotFollowed`, `httpErrorMessages` |
| Upload | Credentials wrong / revoked (401/403, S3 signature) | Points at Settings, no retry storm | Generic "HTTP 403" | **new** `isAuthFailure` → "Check the credentials in Settings → Upload" + "Open Settings"; 4xx never retried | `transport.authFailureNoRetry`, `s3.multipartAbortsOnFailure` |
| Upload | Partial S3 multipart | Abort on failure/cancel | Abort was detached and lost on quit | **new** tracked; quit waits ≤ 2 s | `s3.multipartAbortsOnFailure` |
| Upload | File grows while uploading (re-saved by Annotate) | Whole file uploaded | Multipart loop bounded by the stale size → truncated upload reported as success | **new** read to EOF | `s3.multipartReadsToEOF` |
| Upload | Synced folder destination | Atomic temp + rename, no half files | ok | ok (made testable) | `folder.atomicCopy` |
| Upload | Local file never deleted on failure; source vanished / unreadable | Clear error | Unreadable fell through to an opaque transport error | **new** readable check; "moved or deleted before the upload finished" | `preparation.sourceProblems` |
| Upload | Multi-GB files | Streamed | ok (PUT from file, 8 MB parts) | ok | `transport.streamsFileBody` |
| Upload | "Copy link when upload starts", then failure | User told, dead link cleared | Dead link stayed silently | **new** cleared if still on the clipboard; alert says so | manual |
| Upload | HTTP endpoint retry after 5xx | | May duplicate server-side (non-idempotent POST) | **accepted** | — |
| Upload | Multipart abort lost if the app dies (not quits) | | | **accepted**; recommend an S3 lifecycle rule for incomplete uploads | — |

## 5. Capture, history, overlays, settings

See the rows below; the mechanism for export-location failures is a fallback into the app's own `Media/` library
with a message, so a capture is never lost because the chosen folder went away.

| area | scenario | expected | before | fix | test |
|---|---|---|---|---|---|
| Capture | Screen Recording permission missing or stale TCC cache | Clear alert with "Open System Settings", no file written | Generic "Couldn't capture" alert; a fully transparent image would have been saved | **new** `ScreenCapturer.classified` maps `SCStreamError.userDeclined` / preflight-false → `permissionDenied`; fully transparent output → `.blank`; one shared explanation (`Permissions.explainScreenRecordingProblem`) | `CaptureKit.captureFailures` |
| Capture | Export folder missing / read-only / a file / unmounted volume | Capture kept in the app library with a message | `didCaptureImage` returned nil → capture lost; a recording was marked saved after a failed move | **new** `AppPaths.isWritableDirectory`, `MediaPipeline.usableExportLocation`, fallback to `Media/` with the card shown; `isSaved` only after a successful move; last resort → clipboard; `save()` explains | `Export location probing` |
| Capture | Two captures in the same second; crash mid-write | Never overwrite; never a truncated PNG under the final name | `Data.write(.atomic)` replaced existing files | **new** temp file in the same folder + `renamex_np(RENAME_EXCL)`; the pipeline retries on a collision | `Atomic exclusive image writes` |
| Capture | 3 × 5K displays / absurd sizes | Clear error, no crash | `context` nil → "Screen content error" or a multi-GB allocation attempt | **new** `ImageTools.maxPixelCount` (400 MP), `validateSize`, `checkedContext`, `ImageError.tooLarge/outOfMemory` | `CaptureKit.hugeCaptures` |
| Scrolling | Screen stops answering / zero frames / stitch fails | Keep the partial result; Esc always cleans up | After 5 errors the result was discarded; a capture could hang forever | **new** 10 s timeout per frame; with frames → toast + finish (partial kept); without → explain; Esc/`end()` tears everything down (verified) | `TextKit.stitchKeepsPartialResult` |
| OCR | Vision throws / unsupported language | No crash, clear message | Failure looked like "No text" | **new** error passed through `recognize`; toast in Capture Text, alert in the service API | `TextKit.ocrRobustness` |
| Quick Access | Card closed before save | File kept, "Restore Recently Closed" works | Close never deletes; sweep only at launch and only files older than a day | ok (sweep made testable, skips folders) | `Orphaned media sweep` |
| History | Corrupt `history.json` (truncated, garbage, empty, wrong shape, future version, 5000 entries, `..` paths) | Lenient load, original bytes kept, prune confined to managed folders | Lenient decode, but the rewrite silently dropped the original bytes | **new** `HistoryIndex.load(from:)` writes `history.json.bak` when recovery was needed | `OverlayKit.historyCorruption` |
| Pins / clipboard | 10000 × 10000 image | No freeze | Pin drew the full `NSImage` every redraw; copy re-encoded PNG up front | **new** display-bounded downsample for pins (10000² → 36 MB instead of 400 MB); clipboard PNG provided lazily | `OverlayKit.hugeImagePreview` |
| Overlays | Capture hangs (freeze, SCScreenshotManager never returns) | Overlay torn down, service idle, Esc always escapes | `preparing` stuck forever | **new** `withTimeout` (5 s freeze / 10 s capture), released on time even for non-cancellable work | `CaptureKit.timeout` |
| Hotkeys | Shortcut taken by another app | Reported, app otherwise fine | Silent failure | **new** `HotkeyCenter.unavailable` + warning in Settings → Shortcuts | — |
| Settings | Corrupt defaults (wrong types, garbage JSON) | Defaults used, no crash | ok | ok (verified) | `Defaults corruption` |
| Displays | Pin left on an unplugged display | Pin moved back on screen | Never moved | **new** `PinGeometry.frameKeptOnScreen` on `didChangeScreenParameters` | `OverlayKit.pinsStayOnScreen` |
| Migration | Half-finished Shotcraft move | Resumable; old folder deleted only when empty | Skipped forever once the new folder existed | **new** `mergeMove` per item | `LegacyMigration resumable` |
| Capture | All-black opaque capture | | Treated as real content | **accepted** (only fully transparent output means permission failure) | — |

## 6. Lifecycle

| area | scenario | expected | before | fix | test |
|---|---|---|---|---|---|
| Updates | Swap while recording / annotating | Never | Idle gate: no recording, no uploads, no windows, 10 min idle | ok (+ `isFinalizing`, above); on-quit swap starts only after `applicationShouldTerminate` finished the recording | `UpdateKit` gate + end-to-end |
| Updates | Quit cancelled after the helper was spawned | Staged copy kept, helper stopped | ok | ok | — |
| Migration | Shotcraft → Super Screenshot | Re-pointed paths, runs once | ok | ok | `LegacyMigration *` |
| History | Flush on quit | Index written | `willTerminate` observer | ok (runs after the recording finalized) | — |

## 7. Top residual risks (accepted)

1. Studio cursor/click/keystroke events live in memory until the recording stops; a crash keeps the screen video
   but not the Studio edits (the salvaged file opens in the plain video editor).
2. Up to ~2 s (one fragment) of a recording is lost on a hard crash; finished files are fragmented MP4/MOV.
3. GIF editor loads the whole GIF and re-encodes on the main thread.
4. HTTP-endpoint uploads retried after a 5xx can be duplicated server-side.
