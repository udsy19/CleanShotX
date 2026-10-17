// swift-tools-version:5.10
import PackageDescription

// Super Screenshot — a from-scratch reimplementation of the CleanShot X feature set.
// Every feature lives in its own library target that depends only on SuperScreenshotCore;
// the app target wires them together through the `Services` registry in Core.

let featureModules = [
    "CaptureKit",      // area / window / fullscreen / previous area / self-timer / all-in-one / freeze / desktop icons
    "AnnotateKit",     // image editor + .superscreenshot documents
    "RecordingKit",    // screen recording (video + GIF), recording overlays, video editor/trimmer
    "StudioKit",       // Studio Mode recording + timeline editor (auto zoom, cursor, backgrounds)
    "OverlayKit",      // Quick Access Overlay, pinned screenshots, capture history
    "TextKit",         // OCR (text recognition) + scrolling capture
    "PreferencesKit",  // settings window, onboarding
    "UploadKit",       // uploads / share links
]

var targets: [Target] = [
    .target(name: "SuperScreenshotCore", path: "Sources/SuperScreenshotCore"),
    .executableTarget(
        name: "SuperScreenshot",
        dependencies: ["SuperScreenshotCore"] + featureModules.map { .target(name: $0) },
        path: "Sources/SuperScreenshot"
    ),
    .executableTarget(
        name: "SuperScreenshotSelfTest",
        dependencies: ["SuperScreenshotCore"] + featureModules.map { .target(name: $0) },
        path: "Sources/SuperScreenshotSelfTest"
    ),
]
targets += featureModules.map { .target(name: $0, dependencies: ["SuperScreenshotCore"], path: "Sources/\($0)") }

let package = Package(
    name: "SuperScreenshot",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SuperScreenshot", targets: ["SuperScreenshot"])],
    targets: targets
)
