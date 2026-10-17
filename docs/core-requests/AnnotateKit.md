# AnnotateKit → integrator requests

1. **Declare the project document type in the app's Info.plist** (app target / `scripts/build-app.sh`):
   - `UTExportedTypeDeclarations`: `com.udsy.shotcraft.document`, conforms to `public.data`, extension `shotcraft`,
     description "Shotcraft Project".
   - `CFBundleDocumentTypes`: "Shotcraft Project", role Editor, rank Owner, `LSItemContentTypes = [com.udsy.shotcraft.document]`
     (CleanShot does the same for `com.cleanshot.document`). AnnotateKit already falls back to an extension-based
     dynamic UTType when the declaration is missing (`AnnotateService.projectType`), but Finder double-click and the
     document icon need the declaration. `AppDelegate.openFile` already routes `.shotcraft` to `Services.annotate.openDocument`.

2. **Shared Dock-icon coordinator in Core.** Annotate switches `NSApp` to `.regular` while an editor is open
   (`annotateShowDockIcon`) and back to `.accessory` when the last one closes, unless another titled, visible,
   non-panel window is still up. Other modules (video editor, Studio, Settings) need the same; a ref-counted
   `DockIcon.retain(owner)` / `release(owner)` in Core would remove the heuristic.

3. **Main menu while `.regular`.** When the Dock icon shows, the menu bar shows Shotcraft with no menus. The editor
   handles its own ⌘-shortcuts (undo/redo, copy/paste, save, zoom, arrange) via `EditorWindow.performKeyEquivalent`,
   so nothing breaks, but a standard main menu (App / Edit / Window) from the app target would be more native.

4. Optional: `Clipboard.copy(image:scale:)` that also writes a TIFF with the right DPI so Retina images paste at the
   correct point size in other apps (today PNG data is written without DPI, used by Annotate's ⌘C).
