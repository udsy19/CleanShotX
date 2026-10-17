import AppKit
import SuperScreenshotCore

/// Entry point for the app target. Background updates need nothing from other modules beyond `Services`, and no other
/// module calls into UpdateKit, so nothing is registered in `Services`.
public enum UpdateKitModule {
    /// Cleans up after a previous update and starts the check schedule (Settings → General → Install updates
    /// automatically).
    @MainActor public static func install() { UpdateController.shared.start() }

    /// Call from `applicationWillTerminate`: a downloaded, verified update is installed once the app has quit.
    @MainActor public static func applicationWillTerminate() { UpdateController.shared.installOnQuit() }

    /// Shows "Updated to x.y.z" once after an update; call when the user opens the menu bar menu.
    @MainActor public static func showUpdatedNoticeIfNeeded() { UpdateController.shared.showUpdatedNoticeIfNeeded() }
}
