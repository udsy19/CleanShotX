# Core requests from StudioKit

All earlier requests have been integrated:

1. `StudioServicing.isRecording` / `stopRecording()` — done (StudioKit implements both).
2. Shared Dock-icon presence — done (`DockIcon.set("studio", count:)`).
3. `Sound.Effect.exportDone` — done.

Open:

4. **Main-menu entries for the Studio editor.** CleanShot's File menu has Save ⌘S, Save As…, Export… ⌘E,
   Export & Upload to Cloud… ⌘U, Export Current Frame as Image… ⇧⌘E. The editor handles these shortcuts itself;
   if the app menu gains a File menu, its items can send `saveDocument:` (already implemented by the editor's
   window controller) and the rest could be routed through a small `StudioServicing` extension.
