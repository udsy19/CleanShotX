import AppKit

// MARK: - Media model

public enum MediaKind: String, Codable, Sendable {
    case image, video, gif
    /// A Studio Mode project package (`.superscreenshotvideo`).
    case studioProject
}

public enum CaptureMode: String, Codable, Sendable {
    case area, previousArea, fullscreen, window, selfTimer, allInOne, scrolling, text
    case recording, gifRecording, studio
    case imported

    /// Used for the `%a` file-name token.
    public var fileNameKind: String {
        switch self {
        case .recording, .studio: "Screen Recording"
        case .gifRecording: "GIF"
        case .scrolling: "Scrolling Screenshot"
        case .imported: "Image"
        default: "Screenshot"
        }
    }
}

/// A capture (screenshot, recording, …) that exists as a file on disk.
public final class CapturedMedia: Identifiable, Hashable, Codable, @unchecked Sendable {
    public let id: UUID
    public var url: URL
    public var kind: MediaKind
    public var mode: CaptureMode
    public var createdAt: Date
    /// Pixel dimensions of the image or video.
    public var pixelSize: CGSize
    /// Backing scale factor of the display it came from (2 for Retina).
    public var scale: CGFloat
    /// True once the user explicitly saved it to the export location.
    public var isSaved: Bool
    /// Link returned by the upload provider.
    public var uploadedURL: URL?
    /// Editable Annotate document, if the image has been annotated.
    public var projectURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, url, kind, mode, createdAt, pixelSize, scale, isSaved, uploadedURL, projectURL
    }

    public init(id: UUID = UUID(), url: URL, kind: MediaKind, mode: CaptureMode, createdAt: Date = Date(),
                pixelSize: CGSize, scale: CGFloat, isSaved: Bool = false) {
        self.id = id; self.url = url; self.kind = kind; self.mode = mode; self.createdAt = createdAt
        self.pixelSize = pixelSize; self.scale = scale; self.isSaved = isSaved
    }

    public var isImage: Bool { kind == .image }
    public var isVideoLike: Bool { kind == .video || kind == .gif || kind == .studioProject }
    /// Size in points (pixels / scale).
    public var pointSize: CGSize { CGSize(width: pixelSize.width / max(scale, 1), height: pixelSize.height / max(scale, 1)) }

    public var image: NSImage? {
        guard kind == .image || kind == .gif, let img = NSImage(contentsOf: url) else { return nil }
        img.size = pointSize == .zero ? img.size : pointSize
        return img
    }
    public var cgImage: CGImage? { ImageTools.load(url) }

    public static func == (a: CapturedMedia, b: CapturedMedia) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public static let didChange = Notification.Name("SuperScreenshotMediaDidChange")
    /// Posted by the upload service for every progress tick: `object` = media, `userInfo["fraction"]` = Double 0…1.
    public static let uploadProgress = Notification.Name("SuperScreenshotUploadProgress")
    /// Call after mutating (e.g. file replaced by annotate, uploaded) so overlays/history refresh.
    public func notifyChanged() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}

// MARK: - Area selection (shared by screenshots, recording, OCR, scrolling capture)

public enum SelectionPurpose: Sendable { case screenshot, recording, gifRecording, scrolling, text, studio }

public struct AreaSelectionOptions {
    public var purpose: SelectionPurpose
    /// Highlight windows under the cursor; a click (without drag) selects the window.
    public var allowsWindowSelection: Bool
    /// Pre-populated selection (global Cocoa coordinates).
    public var initialRect: CGRect?
    public var showsDimensions: Bool
    public init(purpose: SelectionPurpose, allowsWindowSelection: Bool = true,
                initialRect: CGRect? = nil, showsDimensions: Bool = true) {
        self.purpose = purpose; self.allowsWindowSelection = allowsWindowSelection
        self.initialRect = initialRect; self.showsDimensions = showsDimensions
    }
}

public struct AreaSelection {
    /// Global Cocoa coordinates (origin at bottom-left of the primary display).
    public var rect: CGRect
    public var screen: NSScreen
    /// Set when the user clicked a window rather than dragging.
    public var windowID: CGWindowID?
    public init(rect: CGRect, screen: NSScreen, windowID: CGWindowID? = nil) {
        self.rect = rect; self.screen = screen; self.windowID = windowID
    }
}

public struct CaptureOptions {
    /// Overrides the after-capture actions from Preferences (e.g. "Capture Area & Copy").
    public var actions: Set<AfterCaptureAction>?
    /// Capture this exact rect (global Cocoa coordinates) without UI (URL scheme API).
    public var rect: CGRect?
    /// Index into `NSScreen.screens` (URL scheme API / fullscreen).
    public var displayIndex: Int?
    public init(actions: Set<AfterCaptureAction>? = nil, rect: CGRect? = nil, displayIndex: Int? = nil) {
        self.actions = actions; self.rect = rect; self.displayIndex = displayIndex
    }
}

// MARK: - Service protocols

@MainActor public protocol CaptureServicing: AnyObject {
    func captureArea(_ options: CaptureOptions)
    func capturePreviousArea(_ options: CaptureOptions)
    func captureFullscreen(_ options: CaptureOptions)
    func captureWindow(_ options: CaptureOptions)
    func selfTimer(_ options: CaptureOptions)
    /// All-In-One: selection overlay with a mode toolbar (screenshot / record / GIF / scrolling / text…).
    func allInOne()
    func pickColor()
    /// Present the shared selection overlay. `completion(nil)` on cancel.
    func selectArea(_ options: AreaSelectionOptions, completion: @escaping (AreaSelection?) -> Void)
    var desktopIconsHidden: Bool { get }
    func setDesktopIconsHidden(_ hidden: Bool)
}

@MainActor public protocol AnnotateServicing: AnyObject {
    func open(_ media: CapturedMedia)
    func open(fileURL: URL)
    func openFromClipboard()
    func openDocument(_ url: URL)
    /// Opens a file picker and annotates the chosen image.
    func openWithPanel()
}

@MainActor public protocol QuickAccessServicing: AnyObject {
    func show(_ media: CapturedMedia)
    func remove(_ media: CapturedMedia)
    func closeAll()
    func saveAll()
    var hasOverlays: Bool { get }
}

@MainActor public protocol PinServicing: AnyObject {
    func pin(_ media: CapturedMedia)
    func pin(image: NSImage, sourceURL: URL?)
    func pinWithPanel()
    func toggleVisibility()
    func closeAll()
    /// True while any pin exists, including pins hidden with `toggleVisibility()`.
    var hasPins: Bool { get }
}

@MainActor public protocol HistoryServicing: AnyObject {
    func add(_ media: CapturedMedia)
    var items: [CapturedMedia] { get }
    func showWindow()
    /// Re-opens the most recent capture in a Quick Access overlay.
    func restoreLast()
    func clear()
    /// Drops an entry immediately (e.g. after the file was trashed elsewhere). Doesn't delete the file.
    func remove(_ media: CapturedMedia)
}

@MainActor public protocol TextServicing: AnyObject {
    /// Select an area and copy its recognized text. `keepLineBreaks` nil = use preference.
    func captureText(keepLineBreaks: Bool?)
    func recognizeText(in image: CGImage, keepLineBreaks: Bool, completion: @escaping (String) -> Void)
    func startScrollingCapture(_ options: CaptureOptions)
    /// Vision's supported recognition languages as (BCP-47 code, localized name), sorted by name.
    func supportedLanguages() -> [(code: String, name: String)]
}

public enum RecordingKind: String, Sendable { case video, gif }

@MainActor public protocol RecordingServicing: AnyObject {
    /// Select an area (or use `rect`) and start recording.
    func startRecording(_ kind: RecordingKind, rect: CGRect?)
    func stopRecording()
    var isRecording: Bool { get }
    /// A stopped recording whose file is still being finalized or converted; quitting now would lose it.
    var isFinalizing: Bool { get }
    func openVideoEditor(_ media: CapturedMedia)
}

@MainActor public protocol StudioServicing: AnyObject {
    func startStudioRecording(rect: CGRect?)
    func openProject(_ url: URL)
    /// True from countdown until the project is written.
    var isRecording: Bool { get }
    func stopRecording()
}

public enum UploadError: LocalizedError {
    case notConfigured, failed(String)
    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Uploading isn't set up. Configure a destination in Settings → Upload."
        case .failed(let m): m
        }
    }
}

@MainActor public protocol UploadServicing: AnyObject {
    var isConfigured: Bool { get }
    /// Uploads, copies the link (per preference) and reports progress 0…1.
    func upload(_ media: CapturedMedia, progress: ((Double) -> Void)?, completion: ((Result<URL, Error>) -> Void)?)
    /// Uploads a tiny probe file with the current settings and deletes it if possible (Settings → "Test").
    func testConnection(completion: @escaping (Result<URL, Error>) -> Void)
    /// Recently uploaded links, newest first.
    var recentUploads: [UploadRecord] { get }
    var isUploading: Bool { get }
    func cancelAll()
}

public struct UploadRecord: Codable, Hashable, Sendable {
    public var fileName: String
    public var url: URL
    public var date: Date
    public init(fileName: String, url: URL, date: Date = Date()) { self.fileName = fileName; self.url = url; self.date = date }
}

@MainActor public protocol PreferencesServicing: AnyObject {
    /// `pane` matches a Preferences tab identifier ("general", "shortcuts", …).
    func show(pane: String?)
    func showOnboarding()
}

/// Late-bound registry so feature modules can call each other without compile-time dependencies.
/// The app target assigns concrete implementations at launch.
@MainActor
public enum Services {
    public static var capture: CaptureServicing!
    public static var annotate: AnnotateServicing!
    public static var quickAccess: QuickAccessServicing!
    public static var pin: PinServicing!
    public static var history: HistoryServicing!
    public static var text: TextServicing!
    public static var recording: RecordingServicing!
    public static var studio: StudioServicing!
    public static var upload: UploadServicing!
    public static var preferences: PreferencesServicing!
    /// Executes any `AppAction` (menu bar, hotkeys, URL scheme, All-In-One toolbar).
    public static var perform: (AppAction) -> Void = { _ in }
}

/// Menu-bar status item hooks implemented by the app target.
@MainActor
public enum StatusBar {
    /// While recording, the status item turns into a stop button showing `elapsed` ("0:42"),
    /// when "Display recording time in menu bar" is on. Clicking it calls `Services.recording.stopRecording()`.
    public static var setRecording: (_ active: Bool, _ elapsed: String?) -> Void = { _, _ in }
    /// Upload progress 0…1 shown in the menu bar icon; nil hides it.
    public static var setProgress: (_ fraction: Double?) -> Void = { _ in }
}
