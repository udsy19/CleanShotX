# Core requests from StudioKit

1. **Stopping a Studio recording from the menu bar / shortcuts.**
   `StatusBar.setRecording` says a click on the status item calls `Services.recording.stopRecording()`, and
   `ActionRouter` only treats `Services.recording.isRecording` as "recording in progress". Studio recordings are
   owned by `Services.studio`, so the menu-bar stop button does nothing for them.
   Proposal: add `var isRecording: Bool { get }` and `func stopRecording()` to `StudioServicing`, and have the
   status item / ActionRouter call `Services.studio.stopRecording()` when `Services.studio.isRecording`.
   (Today StudioKit already treats a second `startStudioRecording` call while recording as "stop".)

2. **Shared Dock-icon presence.** AnnotateKit and StudioKit each flip `NSApp.setActivationPolicy` between
   `.regular` and `.accessory` while their document windows are open, using a "any other titled window visible?"
   heuristic. A small Core helper (`DockPresence.retain(owner)` / `release(owner)`) would avoid modules fighting
   over the policy.

3. **`Sound.Effect.exportDone`** — StudioKit plays `.capture` when an export finishes; a dedicated effect would be
   clearer.
