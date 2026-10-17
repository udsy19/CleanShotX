import AppKit
import SuperScreenshotCore

/// Entry point called once by the app at launch; registers this module's services in `Services`.
public enum CaptureKitModule {
    @MainActor public static func install() {
        Services.capture = CaptureService()
    }
}
