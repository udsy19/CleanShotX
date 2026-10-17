import AppKit
import SuperScreenshotCore

/// Entry point called once by the app at launch; registers this module's services in `Services`.
public enum UploadKitModule {
    @MainActor public static func install() {
        Services.upload = UploadService.shared
    }

    /// Posted during uploads so overlays can draw per-capture progress
    /// (`object`: the `CapturedMedia`, `userInfo["fraction"]`: Double 0…1).
    public static let progressNotification = CapturedMedia.uploadProgress

    /// For `applicationShouldTerminate`: returns true when quitting may proceed. If uploads are running,
    /// asks whether to cancel them (and cancels on confirmation).
    @MainActor public static func confirmTerminationIfUploading() -> Bool {
        guard UploadService.shared.isUploading else { return true }
        let stop = Alerts.confirm("The upload is still in progress. Do you want to cancel it?",
                                  info: "The upload progress will be lost.",
                                  confirmTitle: "Cancel Upload", cancelTitle: "Keep Uploading", destructive: true)
        if stop { UploadService.shared.cancelAll() }
        return stop
    }
}
