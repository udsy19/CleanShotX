// swift-tools-version:5.10
import PackageDescription

// Shotcraft — a from-scratch reimplementation of the CleanShot X feature set.
// Every feature lives in its own library target that depends only on ShotcraftCore;
// the app target wires them together through the `Services` registry in Core.

let featureModules = [
    "CaptureKit",      // area / window / fullscreen / previous area / self-timer / all-in-one / freeze / desktop icons
    "AnnotateKit",     // image editor + .shotcraft documents
    "RecordingKit",    // screen recording (video + GIF), recording overlays, video editor/trimmer
    "StudioKit",       // Studio Mode recording + timeline editor (auto zoom, cursor, backgrounds)
    "OverlayKit",      // Quick Access Overlay, pinned screenshots, capture history
    "TextKit",         // OCR (text recognition) + scrolling capture
    "PreferencesKit",  // settings window, onboarding
    "UploadKit",       // uploads / share links
]

var targets: [Target] = [
    .target(name: "ShotcraftCore", path: "Sources/ShotcraftCore"),
    .executableTarget(
        name: "Shotcraft",
        dependencies: ["ShotcraftCore"] + featureModules.map { .target(name: $0) },
        path: "Sources/Shotcraft"
    ),
    .executableTarget(
        name: "ShotcraftSelfTest",
        dependencies: ["ShotcraftCore"] + featureModules.map { .target(name: $0) },
        path: "Sources/ShotcraftSelfTest"
    ),
]
targets += featureModules.map { .target(name: $0, dependencies: ["ShotcraftCore"], path: "Sources/\($0)") }

let package = Package(
    name: "Shotcraft",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Shotcraft", targets: ["Shotcraft"])],
    targets: targets
)
