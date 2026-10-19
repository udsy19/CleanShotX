# UploadKit — upload pipeline

How CleanShot X 5.0.1 uploads media, and how Super Screenshot maps it to destinations the user owns.
Evidence: the app's class metadata (class/ivar names), its UI strings (UI strings),
`strings` of the arm64 slice (log tags, analytics keys, API paths).

## 1. What CleanShot does

### Components (classes-digest)

| Class | Relevant ivars / selectors | Role |
|---|---|---|
| `CloudAPI` | `session`, `sessionRetryable`, `uploadRequests`, `uploadedMedia` | Alamofire session wrapper; one request per media, a retrying session for idempotent calls. |
| `UploadQueueController` | `jobsQueue`, `activeJobs`, `maxConcurrentOperationCount`, `didCallFinish`, `onFinishHandler` | Operation-queue style job runner; finishes once when the queue drains. |
| `UploadJob` | `delegate`, `task`, `isCancelled`, `uploadRequest`, `retryCount` | One file transfer; cancellable, retried. |
| `S3MultiPartUpload` | `fileURL`, `isUsingTempLocation`, `parts`, `chunkSize`, `totalSize`, `onProgressHandler`, `onFirstChunkUploadedHandler`, `onCancelHandler` | Large files (videos) uploaded in parts straight to S3 via pre-signed part URLs. |
| `S3UploadPart` | `PartNumber`, `url`, `ETag`, `progress` | Per-part state; the `ETag`s feed the completion call. |
| `LegacyChunkedUpload` | `offset`, `uploadId`, `chunkRetryCount` | Older chunked protocol to their own server. |
| `CloudSettings` | `_optimizeScreenshots`, `_copyDirectLink`, `_copyLinkBeforeUpload`, `_showMediaInMenubar`, `_askForNameEveryUpload` | Upload preferences. |
| `CloudMedia` | `id`, `name`, `full_url`, `download_url`, `thumbnail_small_url` | Server record of an uploaded item (link + direct download link). |
| `StatusMenuCloudController` / `StatusMenuCloudItem` / `StatusMenuCloudProgressIndicator` | `progressIndicators`; `openInBrowser`, `copyLink` | Recent uploads in the menu bar menu, progress drawn in the status item. |
| `UploadablePopup` | `uploadButton`, `linkButton`, `cloudProgressView`; `uploadOrCopy`, `copyLink` | Quick Access overlay upload button that turns into "copy link" once uploaded. |
| `LinkVerificator` | — | Checks that a freshly created link resolves before announcing it. |

`isUsingTempLocation` on both upload classes shows the file is first copied/processed into a temp
location (compression for "optimize screenshots", "Set maximum resolution to reduce file size and upload
time.") and the temp copy is deleted afterwards.

### Flow (log tags + analytics keys in the binary)

1. **Prepare** — UI shows "Preparing upload"; screenshots optionally optimized/down-scaled
   (`cloud_optimize_screenshots`, `cloud_uploadScreenshot_compression_error`).
2. **Init** — `cloud_initNewUpload_error` / "There was an error while initiating the upload.": the server
   creates the media record *before* any bytes move, so the share link exists up front.
3. **Transfer** — small files in one request; videos through `S3MultiPartUpload`
   (`[S3MultiPartUpload] Uploading chunk:`, `Success chunk upload`, `Failed chunk upload`) or
   `LegacyChunkedUpload` (`[ChunkedUpload] Chunk upload progress:`, `Global upload progress:`,
   `All chunks uploaded`). Per-chunk retries (`chunkRetryCount`), cancel (`[ChunkedUpload] Upload canceled`).
4. **Complete** — `cloud_completeUpload_error` / "There was an error while completing your upload."
   (S3 CompleteMultipartUpload with the collected `ETag`s).
5. **Link** — "Copy link when upload starts" (`copyLinkBeforeUpload`): because step 2 already produced the
   URL, the link is copied immediately (`onFirstChunkUploadedHandler`) and the HUD says
   "Link has been copied"; otherwise it is copied on success ("Your video is uploaded. The link has been
   copied to your clipboard."). `cloud_copy_direct_link` switches to the raw file URL.
6. **Errors** — "There was an error while uploading your file." / "…your image."; cancelling asks
   "The upload is still in progress. Do you want to cancel it?" / "The upload progress will be lost."
7. **Menu bar** — `StatusMenuCloudProgressIndicator` renders progress in the status item;
   "Show recently uploaded media" lists the last uploads (`v1/media?per_page=3`) with copy/open actions and
   "View All Uploads...". "Update uploaded screenshot" / "Do you want to update the screenshot in Cloud?"
   re-uploads an edited capture to the same link.

## 2. Super Screenshot mapping (user-owned destinations)

CleanShot Cloud is proprietary, so `UploadDestinationKind` offers three destinations; the pipeline shape
stays the same.

| CleanShot | Super Screenshot |
|---|---|
| `UploadQueueController` + `UploadJob` | `UploadQueueController` (serial, `@MainActor`) + `UploadJob` (handlers, bytes, cancel) |
| Alamofire session + retrying session | `UploadTransport`: one `URLSession`, per-task `URLSessionTaskDelegate` for byte progress; `UploadRetryPolicy` retries transient failures (network `URLError`s, HTTP 429/5xx) up to 3 times after 1 s / 3 s / 9 s — never 4xx, never cancellation. Non-2xx → `UploadHTTPError` (status + server detail; 401/403 = credentials). Only 307/308 redirects are followed, so a Wi-Fi sign-in page or S3's "wrong region" 301 surfaces as an error instead of a GET of a web page passing as success. |
| optimize / max resolution, temp location | images wider than `uploadMaxImageWidth` are re-encoded at that width into a temp copy (same format); videos/GIFs uploaded as-is; temp removed after the job |
| init upload → link known up front | S3: object key chosen locally (`<s3PathPrefix><10-char id>/<sanitized name>`); folder: unique file name chosen before copying. Both give the link before the transfer. Custom HTTP only knows the link from the response. |
| `S3MultiPartUpload` (pre-signed parts) | Direct S3 API with AWS Signature V4 (header auth): files > 16 MB use CreateMultipartUpload → UploadPart (8 MB, hashed payload, read to EOF so a capture re-saved while queued still goes up whole) → CompleteMultipartUpload (XML, `<Error>` and HTML in 200 bodies detected); AbortMultipartUpload in the background on failure or cancel (so no orphan parts are billed; a bucket lifecycle rule for incomplete uploads is the backstop if the app dies first). Smaller files: single `PUT` (streamed from disk, `UNSIGNED-PAYLOAD` over HTTPS, hashed over HTTP). |
| `LegacyChunkedUpload` to own server | Custom HTTP: `multipart/form-data` POST (body streamed from a temp file) with user headers; link from a plain-text body or a JSON key path (`data.link`, `files[0].url`). |
| — | Synced folder: chunked copy with progress to a hidden partial file, then atomic move; link = `uploadFolderURLPrefix` + percent-encoded name, or a `file://` URL. |
| `copyLinkBeforeUpload` | `uploadCopyLinkWhenStarts`: copy + HUD "Link has been copied" at start when the link is known (S3/folder), else on completion |
| `StatusMenuCloudProgressIndicator` | `StatusBar.setProgress(fraction)` with the aggregate of the current batch (bytes), `nil` when idle |
| `CloudMedia` list in menu | `recentUploads` (`UploadRecord`, newest first, last 50 persisted in `upload.recentUploads`) |
| "Update uploaded screenshot" | re-uploading the same `CapturedMedia` in a session reuses its S3 key / folder file, so the link stays stable |
| cancel prompt | `UploadKitModule.confirmTerminationIfUploading()` and `cancelAll()`; after confirming, quitting waits up to 2 s for the cancelled transfer to wind down and its multipart abort to go out |

### S3 addressing

- Empty endpoint → AWS: `https://<bucket>.s3.<region>.amazonaws.com/<key>` (virtual-hosted) when the bucket
  name is DNS-safe without dots, otherwise path-style `https://s3.<region>.amazonaws.com/<bucket>/<key>`.
- Custom endpoint (R2, MinIO, B2, Wasabi…) → path-style `<endpoint>/<bucket>/<key>`; if the endpoint host
  already starts with `<bucket>.` it is treated as virtual-hosted. A scheme-less endpoint gets `https://`.
- Public link = `s3PublicURLPrefix` + key when set (CDN / R2 public bucket), else the object URL.
- `x-amz-acl` is not sent; bucket policy decides visibility. The secret lives in the Keychain
  (`Keychain.s3SecretKeyAccount`).

### Success / failure

Success: `media.uploadedURL`, `media.notifyChanged()`, record appended to recents, `Sound.play(.uploadDone)`,
link copied (unless already copied at start). Failure: "There was an error while uploading your file." with the
reason and a way out — "Try Again" re-queues the capture; a credentials failure (401/403) offers "Open Settings"
instead. If the link was copied when the upload started and the transfer then failed, the alert says the link
won't work and removes it from the clipboard when it is still there (a re-upload that re-used an earlier link
keeps it, since the earlier file is still in place). The queue moves on to the next job while the alert is up;
cancellation is silent. Not configured: alert offering "Open Settings" → `Services.preferences.show(pane: "upload")`.

The capture is never deleted or moved by UploadKit: preparation only removes its own temp folder, a failed or
cancelled folder copy removes its partial file, and a source that vanishes mid-transfer is reported as
"moved or deleted before the upload finished". A capture re-saved by Annotate during an upload is written
atomically, so an open transfer keeps streaming the old version (consistent bytes); re-uploading afterwards
refreshes the link. System sleep drops the socket; the transfer fails with a network error after wake and the
retry policy picks it up.

`testConnection` uploads a generated 16×16 PNG named `super-screenshot-test.png` through the same destination,
returns its link, then deletes it (S3 `DELETE`, folder removal; custom HTTP has no delete).

Not reproduced: CleanShot Cloud accounts, tags, passwords/expiry, view counts, link verification against
their CDN, the "direct link" toggle (S3/folder links are already direct).
