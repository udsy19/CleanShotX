import Foundation
import CoreGraphics

// Every user-facing preference, grouped by the Preferences pane that exposes it.
// Recovered from the CleanShot X 5.0.1 binary UI strings (docs/re/raw/ui-sentences.txt) and
// mapped to original key names. Module-private state (last tool, window frames, …) may be declared
// as additional `Defaults.Keys` inside the owning module.

// MARK: - Value types

public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg, heic, tiff
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var displayName: String { self == .jpeg ? "JPG" : rawValue.uppercased() }
    public var utType: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .tiff: "public.tiff"
        }
    }
}

public enum VideoFormat: String, Codable, CaseIterable, Sendable {
    case mp4, mov
    public var fileExtension: String { rawValue }
}

public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    case low, medium, high, original
    public var displayName: String { rawValue.capitalized }
}

/// Things that can happen automatically after a capture. Stored as a set.
public enum AfterCaptureAction: String, Codable, CaseIterable, Sendable {
    case showQuickAccess, copyToClipboard, save, annotate, upload, pin, openVideoEditor
    public var displayName: String {
        switch self {
        case .showQuickAccess: "Show Quick Access Overlay"
        case .copyToClipboard: "Copy file to clipboard"
        case .save: "Save"
        case .annotate: "Open Annotate tool"
        case .upload: "Upload"
        case .pin: "Pin to the screen"
        case .openVideoEditor: "Open Video Editor"
        }
    }
}

public enum ScreenSide: String, Codable, CaseIterable, Sendable { case left, right }

public enum OverlayScreenChoice: String, Codable, CaseIterable, Sendable {
    /// The screen where the cursor is pointing.
    case activeScreen
    case mainScreen
}

public enum SaveButtonBehavior: String, Codable, CaseIterable, Sendable {
    case saveToExportLocation, askForDestination
    public var displayName: String { self == .askForDestination ? "Ask for destination" : "Save to export location" }
}

public enum ClipboardContent: String, Codable, CaseIterable, Sendable {
    /// File reference + image data (paste works in Finder *and* image editors).
    case fileAndImage
    case imageOnly
    case fileOnly
    public var displayName: String {
        switch self {
        case .fileAndImage: "File & Image (default)"
        case .imageOnly: "Image"
        case .fileOnly: "File"
        }
    }
}

public enum WindowBackgroundStyle: String, Codable, CaseIterable, Sendable {
    case transparent, desktopWallpaper, customWallpaper, color
    public var displayName: String {
        switch self {
        case .transparent: "Transparent"
        case .desktopWallpaper: "Desktop wallpaper"
        case .customWallpaper: "Custom wallpaper"
        case .color: "Background color"
        }
    }
}

public enum WallpaperSource: String, Codable, CaseIterable, Sendable { case desktop, custom, color }

public enum CaptureSound: String, Codable, CaseIterable, Sendable {
    case grab, shutter, screenCapture, pop, tink, none
    public var displayName: String {
        switch self {
        case .grab: "Grab"
        case .shutter: "Shutter"
        case .screenCapture: "Screen Capture"
        case .pop: "Pop"
        case .tink: "Tink"
        case .none: "None"
        }
    }
}

public enum OCRLanguageMode: String, Codable, Sendable { case automatic, manual }

public enum UploadDestinationKind: String, Codable, CaseIterable, Sendable {
    /// No uploading configured.
    case none
    /// S3-compatible bucket (AWS, Cloudflare R2, MinIO, …).
    case s3
    /// Multipart POST to a custom endpoint returning a URL.
    case customHTTP
    /// Copy to a folder (e.g. a synced Dropbox/iCloud folder) and build a URL from a prefix.
    case folder
    public var displayName: String {
        switch self {
        case .none: "Not configured"
        case .s3: "S3-compatible storage"
        case .customHTTP: "Custom HTTP endpoint"
        case .folder: "Synced folder"
        }
    }
}

public struct RGBAColor: Codable, Hashable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
}

// MARK: - Keys

public extension Defaults.Keys {
    // General
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
    static let showMenuBarIcon = Key<Bool>("showMenuBarIcon", default: true)
    static let playSounds = Key<Bool>("playSounds", default: true)
    static let captureSound = Key<CaptureSound>("captureSound", default: .grab)
    static let exportLocation = Key<String>("exportLocation", default: AppPaths.defaultExportLocation.path)
    static let afterScreenshotActions = Key<Set<AfterCaptureAction>>("afterScreenshotActions", default: [.showQuickAccess])
    static let afterRecordingActions = Key<Set<AfterCaptureAction>>("afterRecordingActions", default: [.showQuickAccess])
    static let hideDesktopIconsWhileCapturing = Key<Bool>("hideDesktopIconsWhileCapturing", default: false)
    static let clipboardContent = Key<ClipboardContent>("clipboardContent", default: .fileAndImage)
    static let onboardingCompleted = Key<Bool>("onboardingCompleted", default: false)

    // Wallpaper (used by "Hide desktop icons" and window-screenshot backgrounds)
    static let wallpaperSource = Key<WallpaperSource>("wallpaperSource", default: .desktop)
    static let customWallpaperPath = Key<String>("customWallpaperPath", default: "")
    static let wallpaperColor = Key<RGBAColor>("wallpaperColor", default: RGBAColor(r: 0.15, g: 0.16, b: 0.2))
    static let updateWallpaperOnSpaceChange = Key<Bool>("updateWallpaperOnSpaceChange", default: true)

    // Screenshots
    static let screenshotFormat = Key<ImageFormat>("screenshotFormat", default: .png)
    static let jpegQuality = Key<Double>("jpegQuality", default: 0.9)
    static let scaleRetinaScreenshotsTo1x = Key<Bool>("scaleRetinaScreenshotsTo1x", default: false)
    static let convertToSRGB = Key<Bool>("convertToSRGB", default: false)
    static let addBorderToScreenshots = Key<Bool>("addBorderToScreenshots", default: false)
    static let showCursorOnScreenshots = Key<Bool>("showCursorOnScreenshots", default: false)
    static let freezeScreenWhenCapturing = Key<Bool>("freezeScreenWhenCapturing", default: false)
    static let crosshairMode = Key<Bool>("crosshairMode", default: false)
    static let showMagnifier = Key<Bool>("showMagnifier", default: false)
    static let rememberLastSelection = Key<Bool>("rememberLastSelection", default: false)
    static let selfTimerSeconds = Key<Int>("selfTimerSeconds", default: 5)
    // Window screenshots
    static let captureWindowShadow = Key<Bool>("captureWindowShadow", default: true)
    static let windowBackgroundStyle = Key<WindowBackgroundStyle>("windowBackgroundStyle", default: .transparent)
    static let windowBackgroundColor = Key<RGBAColor>("windowBackgroundColor", default: .white)
    static let windowBackgroundPadding = Key<Double>("windowBackgroundPadding", default: 48)

    // File naming
    static let fileNameTemplate = Key<String>("fileNameTemplate", default: FileNameTemplate.defaultTemplate)
    static let askForNameAfterCapture = Key<Bool>("askForNameAfterCapture", default: false)

    // Quick Access Overlay
    static let quickAccessSide = Key<ScreenSide>("quickAccessSide", default: .left)
    static let quickAccessScreen = Key<OverlayScreenChoice>("quickAccessScreen", default: .activeScreen)
    static let quickAccessSize = Key<Double>("quickAccessSize", default: 1.0) // scale factor 0.6…1.4
    static let quickAccessAutoClose = Key<Bool>("quickAccessAutoClose", default: false)
    static let quickAccessAutoCloseSeconds = Key<Int>("quickAccessAutoCloseSeconds", default: 10)
    static let quickAccessAutoCloseAction = Key<AfterCaptureAction?>("quickAccessAutoCloseAction", default: nil)
    static let quickAccessCloseAfterDragging = Key<Bool>("quickAccessCloseAfterDragging", default: true)
    static let quickAccessCloseAfterUploading = Key<Bool>("quickAccessCloseAfterUploading", default: true)
    static let quickAccessSaveBehavior = Key<SaveButtonBehavior>("quickAccessSaveBehavior", default: .saveToExportLocation)
    static let quickAccessShowUploadButton = Key<Bool>("quickAccessShowUploadButton", default: true)

    // Recording
    static let videoFormat = Key<VideoFormat>("videoFormat", default: .mp4)
    static let videoFPS = Key<Int>("videoFPS", default: 60)
    static let videoQuality = Key<VideoQuality>("videoQuality", default: .high)
    static let scaleRetinaVideosTo1x = Key<Bool>("scaleRetinaVideosTo1x", default: false)
    static let gifFPS = Key<Int>("gifFPS", default: 15)
    static let gifMaxWidth = Key<Int>("gifMaxWidth", default: 1280)
    static let recordShowCursor = Key<Bool>("recordShowCursor", default: true)
    static let recordHighlightClicks = Key<Bool>("recordHighlightClicks", default: false)
    static let clickHighlightColor = Key<RGBAColor>("clickHighlightColor", default: RGBAColor(r: 0.04, g: 0.52, b: 1, a: 1))
    static let recordShowKeystrokes = Key<Bool>("recordShowKeystrokes", default: false)
    static let recordHideCursorWhenNotMoving = Key<Bool>("recordHideCursorWhenNotMoving", default: false)
    static let recordDimScreen = Key<Bool>("recordDimScreen", default: false)
    static let recordShowControls = Key<Bool>("recordShowControls", default: true)
    static let recordShowTimeInMenuBar = Key<Bool>("recordShowTimeInMenuBar", default: true)
    static let recordCountdown = Key<Bool>("recordCountdown", default: true)
    static let recordCountdownSeconds = Key<Int>("recordCountdownSeconds", default: 3)
    static let recordMicrophone = Key<Bool>("recordMicrophone", default: false)
    static let microphoneDeviceID = Key<String>("microphoneDeviceID", default: "")
    static let recordSystemAudio = Key<Bool>("recordSystemAudio", default: false)
    static let recordAudioMono = Key<Bool>("recordAudioMono", default: false)
    static let recordCamera = Key<Bool>("recordCamera", default: false)
    static let cameraDeviceID = Key<String>("cameraDeviceID", default: "")
    static let recordDoNotDisturb = Key<Bool>("recordDoNotDisturb", default: false)
    static let recordInStudioMode = Key<Bool>("recordInStudioMode", default: false)
    static let rememberLastRecordingArea = Key<Bool>("rememberLastRecordingArea", default: true)

    // Annotate
    static let annotateAlwaysOnTop = Key<Bool>("annotateAlwaysOnTop", default: false)
    static let annotateShowDockIcon = Key<Bool>("annotateShowDockIcon", default: true)
    static let annotateSmoothDrawing = Key<Bool>("annotateSmoothDrawing", default: true)
    static let annotateShowColorNames = Key<Bool>("annotateShowColorNames", default: false)
    static let annotateDrawShadow = Key<Bool>("annotateDrawShadow", default: true)
    static let annotateExpandCanvas = Key<Bool>("annotateExpandCanvas", default: true)
    static let annotateInverseArrow = Key<Bool>("annotateInverseArrow", default: false)
    static let annotateRememberBackgroundTool = Key<Bool>("annotateRememberBackgroundTool", default: false)
    static let annotateSaveBehavior = Key<SaveButtonBehavior>("annotateSaveBehavior", default: .saveToExportLocation)
    static let annotateSnapCrop = Key<Bool>("annotateSnapCrop", default: true)

    // Text recognition
    static let ocrKeepLineBreaks = Key<Bool>("ocrKeepLineBreaks", default: true)
    static let ocrLanguageMode = Key<OCRLanguageMode>("ocrLanguageMode", default: .automatic)
    static let ocrLanguages = Key<[String]>("ocrLanguages", default: ["en-US"])
    static let ocrOpenLinks = Key<Bool>("ocrOpenLinks", default: false)

    // Pinned screenshots
    static let pinLockAndHideOnHover = Key<Bool>("pinLockAndHideOnHover", default: false)
    static let pinShowShadow = Key<Bool>("pinShowShadow", default: true)

    // Capture history
    static let historyEnabled = Key<Bool>("historyEnabled", default: true)
    static let historyRetentionDays = Key<Int>("historyRetentionDays", default: 30) // 0 = forever

    // Upload
    static let uploadDestination = Key<UploadDestinationKind>("uploadDestination", default: .none)
    static let uploadCopyLinkWhenStarts = Key<Bool>("uploadCopyLinkWhenStarts", default: true)
    static let uploadMaxImageWidth = Key<Int>("uploadMaxImageWidth", default: 0) // 0 = original
    static let s3Endpoint = Key<String>("s3Endpoint", default: "")
    static let s3Region = Key<String>("s3Region", default: "us-east-1")
    static let s3Bucket = Key<String>("s3Bucket", default: "")
    static let s3AccessKeyID = Key<String>("s3AccessKeyID", default: "")
    static let s3PublicURLPrefix = Key<String>("s3PublicURLPrefix", default: "")
    static let s3PathPrefix = Key<String>("s3PathPrefix", default: "shotcraft/")
    static let customHTTPEndpoint = Key<String>("customHTTPEndpoint", default: "")
    static let customHTTPFieldName = Key<String>("customHTTPFieldName", default: "file")
    static let customHTTPHeaders = Key<[String: String]>("customHTTPHeaders", default: [:])
    static let customHTTPResponseURLPath = Key<String>("customHTTPResponseURLPath", default: "url")
    static let uploadFolderPath = Key<String>("uploadFolderPath", default: "")
    static let uploadFolderURLPrefix = Key<String>("uploadFolderURLPrefix", default: "")

    // Advanced
    static let allowURLSchemeAPI = Key<Bool>("allowURLSchemeAPI", default: false)
    static let urlSchemeTrustedApps = Key<[String]>("urlSchemeTrustedApps", default: [])
    static let suppressedWarnings = Key<Set<String>>("suppressedWarnings", default: [])
    static let lastCaptureArea = Key<CodableRect?>("lastCaptureArea", default: nil)
    static let lastRecordingArea = Key<CodableRect?>("lastRecordingArea", default: nil)
}

/// A rect in global *Cocoa* screen coordinates (origin bottom-left of the primary display).
public struct CodableRect: Codable, Hashable, Sendable {
    public var x, y, width, height: Double
    public init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.width; height = r.height }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
