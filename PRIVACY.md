# Privacy

**Shotcraft is a local app. Nothing leaves your Mac unless you upload it yourself.**

## What Shotcraft does not do

- **No accounts.** There is nothing to sign up for.
- **No analytics or telemetry.** Shotcraft never phones home, tracks usage or sends crash reports.
- **No servers.** The project doesn't operate any; there is nowhere for your data to go.

## What stays on your Mac

| Data | Location |
|---|---|
| Screenshots and recordings you haven't saved | `~/Library/Application Support/Shotcraft/Media` and `…/Recordings` |
| Studio projects and Annotate documents | `~/Library/Application Support/Shotcraft/Projects` (or wherever you save them) |
| Capture History index | `~/Library/Application Support/Shotcraft/History` — retention is configurable, or turn History off |
| Settings | `~/Library/Preferences/com.udsy.shotcraft.plist` |
| Upload credentials (S3 secret key) | macOS Keychain |

Text recognition, scrolling-capture stitching, video encoding and everything else runs on-device using Apple's
frameworks (Vision, ScreenCaptureKit, AVFoundation).

## Uploads (opt-in)

Uploading is off until you configure a destination in **Settings → Upload**. When you upload, the file goes
directly from your Mac to the destination **you** chose — your own S3-compatible bucket, your own HTTP endpoint,
or a folder on your disk. Shotcraft is not involved beyond sending the request.

## Permissions

| Permission | Why |
|---|---|
| Screen & System Audio Recording | Taking screenshots and recordings |
| Accessibility (optional) | Showing keystrokes in recordings, auto-scroll during scrolling capture |
| Microphone / Camera (optional) | Only when you turn them on for a recording |

## Removing everything

Run `curl -fsSL https://udsy19.github.io/CleanShotX/install.sh | bash -s -- --uninstall`, then delete
`~/Library/Application Support/Shotcraft` and `~/Library/Preferences/com.udsy.shotcraft.plist`.
