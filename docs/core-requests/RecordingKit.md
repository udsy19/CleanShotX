# Core requests from RecordingKit

None of these block RecordingKit; each is implemented privately or degrades gracefully today.

1. **Cancellable menu-bar progress.** CleanShot's `StatusMenuProgressIndicator` has `cancelGifClicked`.
   RecordingKit drives `StatusBar.setProgress(_:)` while encoding a GIF, but the menu bar can't cancel it.
   Proposal: `StatusBar.setProgress(_ fraction: Double?, title: String? = nil, onCancel: (() -> Void)? = nil)`.
   Cancel is currently only offered in RecordingKit's own GIF progress popup.

2. **Missing recording settings keys** (recovered from `ScreenRecordingSettings` ivars):
   `_mergeAudioTracks` (Bool, default false), `_optimizeGifs` (Bool), `_gifQuality` (Int/enum),
   `_maxResolution`. RecordingKit always writes separate mic/system tracks and doesn't optimize GIFs.

3. **Return without a selection in `selectArea`.** RecordingKit treats an `AreaSelection` whose rect is
   smaller than 2×2 pt as "record the whole `selection.screen`". Please document (or guarantee) that
   CaptureKit returns either the full screen frame or an empty rect in that case.

4. **`Sound.Effect.recordResume`** (optional). Pause and resume both use `.recordPause` now.
