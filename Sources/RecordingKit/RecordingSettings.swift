import AppKit
import AVFoundation
import SuperScreenshotCore

enum CameraShape: String, Codable, CaseIterable {
    case circle, square, rectangle
    var title: String { rawValue.capitalized }
    /// Width / height.
    var aspect: CGFloat { self == .rectangle ? 16.0 / 9 : 1 }
}

enum CameraSize: String, Codable, CaseIterable {
    case small, medium, large
    var title: String { rawValue.capitalized }
    /// Height of the bubble.
    var points: CGFloat {
        switch self {
        case .small: 120
        case .medium: 160
        case .large: 240
        }
    }
}

/// Click highlight look: a ring around a solid dot, or a translucent disc.
enum ClickStyle: String, Codable, CaseIterable {
    case outline, filled
    var title: String { rawValue.capitalized }
}

extension Defaults.Keys {
    static let rkCameraShape = Key<CameraShape>("recordingKit.cameraShape", default: .circle)
    static let rkCameraSize = Key<CameraSize>("recordingKit.cameraSize", default: .medium)
    static let rkCameraMirror = Key<Bool>("recordingKit.cameraMirror", default: true)
    static let rkClickStyle = Key<ClickStyle>("recordingKit.clickStyle", default: .outline)
    static let rkKeystrokesShortcutsOnly = Key<Bool>("recordingKit.keystrokesShortcutsOnly", default: true)
    static let rkExportQuality = Key<VideoQuality>("recordingKit.exportQuality", default: .original)
    /// Export resolution as a short-side pixel count; 0 = original.
    static let rkExportShortSide = Key<Int>("recordingKit.exportShortSide", default: 0)
}

/// Capture-device discovery for the microphone / camera menus.
enum AVDevices {
    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// The selected microphone, falling back to the system default when the stored one is gone.
    static var selectedMicrophone: AVCaptureDevice? {
        let id = Defaults[.microphoneDeviceID]
        if !id.isEmpty, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    static var selectedCamera: AVCaptureDevice? {
        let id = Defaults[.cameraDeviceID]
        if !id.isEmpty, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .video) ?? cameras.first
    }
}

/// Requests camera/microphone access, explaining how to fix it when denied.
@MainActor
enum DeviceAccess {
    static func ensure(_ media: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch Permissions.status(for: media) {
        case .authorized: completion(true)
        case .notDetermined: Permissions.request(media, completion: completion)
        default:
            let isMic = media == .audio
            let a = NSAlert()
            a.messageText = isMic ? "Microphone access required" : "Camera access required"
            a.informativeText = "Allow Super Screenshot in System Settings → Privacy & Security → \(isMic ? "Microphone" : "Camera")."
            a.addButton(withTitle: "Open System Settings")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { Permissions.openSettings(isMic ? .microphone : .camera) }
            completion(false)
        }
    }
}

/// Builds an SF Symbol image.
func symbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .medium) -> NSImage {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    return img.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? img
}

/// Carries a non-Sendable reference into a `@Sendable` closure when the caller guarantees safe use
/// (e.g. thread-safe AVFoundation objects, or objects only touched on one queue).
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
