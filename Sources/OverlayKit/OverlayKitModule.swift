import AppKit
import SuperScreenshotCore

/// Entry point called once by the app at launch; registers this module's services in `Services`.
public enum OverlayKitModule {
    @MainActor public static func install() {
        Services.quickAccess = QuickAccessController.shared
        Services.pin = PinController.shared
        Services.history = HistoryStore.shared
    }
}
