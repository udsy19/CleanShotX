import AppKit
import ShotcraftCore

/// Entry point called once by the app at launch; registers this module's services in `Services`.
public enum AnnotateKitModule {
    @MainActor public static func install() {
        Services.annotate = AnnotateService.shared
    }
}
