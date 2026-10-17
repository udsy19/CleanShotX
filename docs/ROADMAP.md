# Roadmap

Shotcraft 1.0 covers the full capture → annotate → share workflow. These are the known gaps and next steps.
Contributions are welcome — see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Distribution
- [ ] Developer ID signing + notarization (removes the first-launch "Open Anyway" step for DMG downloads)
- [ ] Homebrew cask
- [ ] In-app update checks

## Capture & overlays
- [ ] Hold ⌥ while dragging a Quick Access card to keep it on screen; ⌥-Save to pick a destination
- [ ] Rotate / flip in the Quick Access context menu
- [ ] Resize the area after starting a scrolling capture

## Annotate
- [ ] ⌥ while drawing an arrow inverts its direction
- [ ] Rotate / flip in crop mode
- [ ] Retina-aware clipboard (TIFF with DPI) so images paste at point size everywhere

## Recording & Studio
- [ ] Cancel GIF rendering / uploads from the menu bar progress indicator
- [ ] Settings for merging microphone + system audio into one track, GIF optimisation and maximum resolution
- [ ] Studio: Save As, custom export dimensions, File-menu entries (Export ⌘E), "zoom to focused text field"
- [ ] Per-track volume in the video editor; Do Not Disturb while recording (no public API today)
