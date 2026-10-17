# Core requests from OverlayKit

1. **Orphaned unsaved captures when History is disabled.** `MediaPipeline` writes unsaved captures to
   `AppPaths.media`; OverlayKit only deletes such files when their History entry expires or History is cleared.
   With `.historyEnabled == false` nothing indexes them, so they accumulate. Suggest either always indexing
   (and hiding the History UI when disabled) or a Core-level sweep of `AppPaths.media` files older than a day
   that no window/overlay references. OverlayKit deliberately does not sweep the folder itself because other
   modules (Annotate, Recording) may hold files there.

2. **`HistoryServicing.remove(_ media: CapturedMedia)`** (optional). Other modules that delete or trash a
   capture (e.g. Annotate "Move to Trash") currently rely on History dropping entries whose file disappeared
   (checked at launch, hourly and on every add). An explicit removal call would make that immediate.

3. **Upload "Link has been copied" feedback.** Quick Access shows its own in-card done state; if UploadKit also
   shows a HUD for uploads started from Quick Access, the user sees both. Consider an `UploadServicing.upload`
   option to suppress the HUD when the caller renders progress itself.
