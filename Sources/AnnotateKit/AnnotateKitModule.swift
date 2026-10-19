import AppKit
import SuperScreenshotCore

/// Entry point called once by the app at launch; registers this module's services in `Services`.
public enum AnnotateKitModule {
    @MainActor public static func install() {
        Services.annotate = AnnotateService.shared
    }

    /// After launch: if the app quit (crash, force quit, power loss) while annotation edits were unsaved,
    /// asks whether to reopen or delete them.
    @MainActor public static func recoverUnsavedDocuments() {
        AnnotateService.shared.recoverUnsavedDocuments()
    }

    /// For `applicationShouldTerminate`: returns true when quitting may proceed. Editors with unsaved edits
    /// are brought forward and ask Save / Don't Save / Cancel first (⌘Q does not go through windowShouldClose).
    @MainActor public static func confirmTerminationIfUnsaved() -> Bool {
        AnnotateService.shared.confirmTerminationIfUnsaved()
    }
}
