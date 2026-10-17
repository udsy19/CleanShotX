# Shotcraft

A from-scratch macOS screenshot & screen-recording app that reimplements the feature set of
**CleanShot X 5.0.1**, reconstructed by studying the installed app. Independent project — not affiliated with CleanShot X / MTW.
No CleanShot code, images or sounds are used.

## Build & run

Requirements: macOS 14+, Swift 6 toolchain (Command Line Tools are enough — no Xcode needed).

```sh
./scripts/signing-setup.sh        # once: project-local self-signed identity so permissions survive rebuilds
./scripts/build-extensions.sh     # share + Quick Look extensions (optional)
./scripts/build-app.sh            # → build/Shotcraft.app   (add --debug for a faster build)
open build/Shotcraft.app
swift run ShotcraftSelfTest       # headless logic tests
./scripts/e2e.sh                  # end-to-end suite against the running app (see docs/TESTING.md)
./scripts/make-dmg.sh             # universal, signed DMG in dist/
```

On first launch Shotcraft walks you through Screen Recording permission (and optional Accessibility for
keystroke display / auto-scroll). It lives in the menu bar.

## Features

| Area | What you get |
|---|---|
| Screenshots | Area (crosshair, magnifier, window snapping, Shift/Option/Space modifiers, arrow-key nudge), previous area, fullscreen, window (with shadow + wallpaper/color backgrounds), self-timer, freeze screen, All-In-One overlay with size/aspect-ratio controls |
| Quick Access Overlay | Floating thumbnails with copy / save / annotate / upload / pin / drag-out / Quick Look, auto-close, save-all/close-all |
| Annotate | Crop, shapes, arrows (5 styles), text styles, pen, highlighter, pixelate/blur/redact, spotlight, counters, images, background tool (gradients, wallpaper, padding, ratio), undo/redo, `.shotcraft` documents |
| Pinned screenshots | Always-on-top, resizable, opacity, click-through lock |
| Screen recording | Video or GIF, mic + system audio, camera overlay, click highlights, keystrokes, countdown, pause/restart, video editor & trimmer |
| Studio Mode | Cursor-tracked recordings with auto-zoom, smooth cursor, backgrounds, camera bubble and a timeline editor |
| Text recognition | OCR with line-break control, language detection, QR codes |
| Scrolling capture | Manual or auto-scroll, vertical or horizontal stitching |
| Capture history | Searchable grid of recent captures, restore last capture |
| Upload | Your own S3-compatible bucket, custom HTTP endpoint or synced folder; link copied automatically |
| Automation | Global shortcuts for every action and a `shotcraft://` URL scheme compatible with CleanShot's API commands |
| Extensions | "Annotate" and "Pin to the Screen" share-menu items; Quick Look previews/thumbnails for documents |

## URL scheme

`shotcraft://<command>?<params>` — e.g. `shotcraft://capture-area?action=copy`,
`shotcraft://capture-area?x=0&y=0&width=800&height=600&display=1`, `shotcraft://capture-text?linebreaks=false`,
`shotcraft://record-screen`, `shotcraft://open-annotate?filepath=/path/img.png`, `shotcraft://pin?filepath=…`,
`shotcraft://toggle-desktop-icons`, `shotcraft://open-settings?tab=shortcuts`.
Screen-reading commands require enabling **Settings → Advanced → Allow URL scheme API** (you're asked on first use).

## Installing from the DMG

Open `Shotcraft-<version>.dmg`, drag Shotcraft to Applications, then open it. The app is self-signed (not notarized),
so the first launch shows a warning: open System Settings → Privacy & Security and click **Open Anyway**. Requires
macOS 14+ on Apple silicon or Intel.

## Project docs

- `docs/ARCHITECTURE.md` — module layout and contracts
- `docs/re/*.md` — reverse-engineered feature specs per area, with evidence
- `docs/TESTING.md` — test layers, what was verified end to end, bugs found
