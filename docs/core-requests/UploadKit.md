# UploadKit → Core / app-target requests

1. **Quit while uploading** (app target). In `applicationShouldTerminate`, call
   `UploadKitModule.confirmTerminationIfUploading()` and return `.terminateCancel` when it returns false.
   It asks "The upload is still in progress. Do you want to cancel it?" and cancels uploads on confirmation.

2. **Per-capture upload progress** (Core). UploadKit posts `Notification.Name("ShotcraftUploadProgress")`
   with the `CapturedMedia` as `object` and `userInfo["fraction"]: Double` (0…1) for every upload, including
   ones started by `MediaPipeline` with `progress: nil`. OverlayKit can't import UploadKit, so please declare
   the name in Core (for example `public static let uploadProgress = Notification.Name("ShotcraftUploadProgress")`
   on `CapturedMedia`). The Quick Access overlay can then draw progress like CleanShot's `cloudProgressView`.
   Completion is already signalled by `CapturedMedia.didChange`, since `uploadedURL` gets set.

3. **Cancel from the menu bar** (Core + app). CleanShot's `StatusMenuCloudProgressIndicator` lets the user
   stop an upload. Suggested: add `func cancelAll()` and `var isUploading: Bool` to `UploadServicing`.
   `UploadService` already implements both as public members, so this only needs the protocol change. The
   status item can then offer "Cancel Upload" while `StatusBar.setProgress` is non-nil.

4. **Recent uploads menu** (app target). "Show recently uploaded media" / "View All Uploads...": the status
   menu can list `Services.upload.recentUploads.prefix(3)` (CleanShot fetches `v1/media?per_page=3`), with
   copy-link and open-in-browser actions. The list is persisted (last 50) under `upload.recentUploads`.
