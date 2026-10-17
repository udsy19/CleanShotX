import Foundation
import CoreGraphics
import ShotcraftCore

// Studio Mode project model ("Flow" in CleanShot X: FLProject / FLClip / FLZoom / FLDocument).
// All times are *source* seconds (seconds into screen.mov) unless a name says otherwise.
// All recorded positions are normalized to the recorded area with a TOP-LEFT origin (x right, y down).

/// A normalized point (0…1 in both axes, top-left origin).
public struct NPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let center = NPoint(x: 0.5, y: 0.5)
    public func distance(to o: NPoint) -> Double { hypot(x - o.x, y - o.y) }
    public static func lerp(_ a: NPoint, _ b: NPoint, _ t: Double) -> NPoint {
        NPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    public var clamped: NPoint { NPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }
}

// MARK: - Recorded events (events.json)

/// What the system cursor looked like at a sample (classified at record time).
public enum CursorKind: Int, Codable, Sendable { case arrow = 0, iBeam = 1, pointingHand = 2 }

/// One polled cursor position. Encoded compactly as `[t, x, y, kind]`.
public struct CursorSample: Codable, Hashable, Sendable {
    public var t: Double
    public var p: NPoint
    public var kind: CursorKind
    public init(t: Double, p: NPoint, kind: CursorKind = .arrow) { self.t = t; self.p = p; self.kind = kind }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        t = try c.decode(Double.self)
        p = NPoint(x: try c.decode(Double.self), y: try c.decode(Double.self))
        kind = CursorKind(rawValue: (try? c.decode(Int.self)) ?? 0) ?? .arrow
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(Self.round(t, 4)); try c.encode(Self.round(p.x, 5)); try c.encode(Self.round(p.y, 5)); try c.encode(kind.rawValue)
    }
    static func round(_ v: Double, _ digits: Int) -> Double {
        let m = pow(10, Double(digits)); return (v * m).rounded() / m
    }
}

public enum MouseButton: Int, Codable, Sendable { case left = 0, right = 1, other = 2 }

public struct ClickEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var p: NPoint
    public var button: MouseButton
    /// true = button pressed, false = released.
    public var down: Bool
    public init(t: Double, p: NPoint, button: MouseButton = .left, down: Bool) {
        self.t = t; self.p = p; self.button = button; self.down = down
    }
}

public struct ScrollEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var p: NPoint
    public var dx: Double
    public var dy: Double
    public init(t: Double, p: NPoint, dx: Double, dy: Double) { self.t = t; self.p = p; self.dx = dx; self.dy = dy }
}

public struct KeyEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue` masked to device-independent flags.
    public var modifiers: UInt
    /// `charactersIgnoringModifiers` at record time.
    public var characters: String
    public init(t: Double, keyCode: UInt16, modifiers: UInt, characters: String) {
        self.t = t; self.keyCode = keyCode; self.modifiers = modifiers; self.characters = characters
    }
}

/// Everything the trackers logged during a Studio recording, aligned to the screen.mov timeline.
public struct StudioEvents: Codable, Equatable, Sendable {
    public var version = 1
    public var cursor: [CursorSample] = []
    public var clicks: [ClickEvent] = []
    public var scrolls: [ScrollEvent] = []
    public var keys: [KeyEvent] = []
    /// False when Accessibility permission was missing, so keystrokes could not be captured.
    public var keystrokesCaptured = true
    public init() {}

    /// Every list is optional, so a file missing one (or from a newer build) still yields the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, 1)
        cursor = c.value(.cursor, []); clicks = c.value(.clicks, []); scrolls = c.value(.scrolls, []); keys = c.value(.keys, [])
        keystrokesCaptured = c.value(.keystrokesCaptured, true)
    }

}

// MARK: - Timeline objects

public struct StudioClip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Source seconds.
    public var start: Double
    public var duration: Double
    public var end: Double { start + duration }
    public init(id: UUID = UUID(), start: Double, duration: Double) { self.id = id; self.start = start; self.duration = duration }
}

public enum ZoomMode: String, Codable, CaseIterable, Sendable {
    case manual, followCursor
    public var title: String { self == .manual ? "Manual" : "Follow Cursor" }
}

public struct ZoomSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    /// Magnification (1 = none).
    public var level: Double
    public var mode: ZoomMode
    /// Focus point for `.manual` (normalized, top-left origin).
    public var focus: NPoint
    public var duration: Double { end - start }
    public init(id: UUID = UUID(), start: Double, end: Double, level: Double, mode: ZoomMode = .manual, focus: NPoint = .center) {
        self.id = id; self.start = start; self.end = end; self.level = level; self.mode = mode; self.focus = focus
    }
}

/// A plain time range on a lane (camera full-screen segments).
public struct TimeSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public init(id: UUID = UUID(), start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
}

// MARK: - Style

public enum GradientPreset: Int, Codable, CaseIterable, Sendable {
    case dusk, ocean, sunrise, forest, grape, ember, mint, slate, candy, midnight
    public var colors: [RGBAColor] {
        switch self {
        case .dusk: [RGBAColor(r: 0.36, g: 0.27, b: 0.86), RGBAColor(r: 0.93, g: 0.42, b: 0.62)]
        case .ocean: [RGBAColor(r: 0.05, g: 0.45, b: 0.85), RGBAColor(r: 0.27, g: 0.85, b: 0.86)]
        case .sunrise: [RGBAColor(r: 0.98, g: 0.55, b: 0.24), RGBAColor(r: 0.99, g: 0.83, b: 0.36)]
        case .forest: [RGBAColor(r: 0.07, g: 0.40, b: 0.30), RGBAColor(r: 0.55, g: 0.83, b: 0.45)]
        case .grape: [RGBAColor(r: 0.42, g: 0.13, b: 0.62), RGBAColor(r: 0.20, g: 0.20, b: 0.55)]
        case .ember: [RGBAColor(r: 0.70, g: 0.10, b: 0.16), RGBAColor(r: 0.98, g: 0.47, b: 0.22)]
        case .mint: [RGBAColor(r: 0.62, g: 0.95, b: 0.82), RGBAColor(r: 0.36, g: 0.68, b: 0.95)]
        case .slate: [RGBAColor(r: 0.20, g: 0.23, b: 0.29), RGBAColor(r: 0.45, g: 0.50, b: 0.58)]
        case .candy: [RGBAColor(r: 0.99, g: 0.60, b: 0.75), RGBAColor(r: 0.62, g: 0.66, b: 0.99)]
        case .midnight: [RGBAColor(r: 0.02, g: 0.03, b: 0.10), RGBAColor(r: 0.15, g: 0.18, b: 0.38)]
        }
    }
}

public enum StudioBackground: Codable, Hashable, Sendable {
    case none
    case color(RGBAColor)
    case gradient(GradientPreset)
    /// A desktop picture (absolute path, e.g. in /System/Library/Desktop Pictures).
    case wallpaper(path: String)
    /// A user-chosen image copied into the project package (file name relative to the package).
    case image(fileName: String)

    public var isNone: Bool { if case .none = self { return true }; return false }
}


public enum AspectRatio: String, Codable, CaseIterable, Sendable {
    // Declaration order is the popup order.
    case auto, square, standard4x3, classic3x2, wide16x9, wide16x10, vertical9x16, portrait3x4
    public var title: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .standard4x3: "4:3"
        case .classic3x2: "3:2"
        case .wide16x9: "16:9"
        case .wide16x10: "16:10"
        case .vertical9x16: "9:16"
        case .portrait3x4: "3:4"
        }
    }
    /// width / height; nil = follow the recording.
    public var value: Double? {
        switch self {
        case .auto: nil
        case .square: 1
        case .standard4x3: 4.0 / 3
        case .classic3x2: 3.0 / 2
        case .wide16x9: 16.0 / 9
        case .wide16x10: 16.0 / 10
        case .vertical9x16: 9.0 / 16
        case .portrait3x4: 3.0 / 4
        }
    }
}

public enum CursorStyle: String, Codable, CaseIterable, Sendable {
    /// Black arrow with white outline (system look; I-beam / hand shapes are kept).
    case macOS
    /// White arrow with black outline.
    case inverted
    /// Translucent touch-style dot.
    case touch
    public var title: String {
        switch self {
        case .macOS: "macOS"
        case .inverted: "Alternative"
        case .touch: "Dot"
        }
    }
}

public enum ClickEffect: String, Codable, CaseIterable, Sendable {
    case none, ripple
}

/// Look of the click highlight (Settings → Click highlight: Outline / Filled).
public enum ClickStyle: String, Codable, CaseIterable, Sendable {
    case outline, filled
    public var title: String { rawValue.capitalized }
}

/// Named click colours (the "Color" popup).
public enum ClickColor: String, CaseIterable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, white
    public var title: String { rawValue.capitalized }
    public var rgba: RGBAColor {
        switch self {
        case .blue: RGBAColor(r: 0.04, g: 0.52, b: 1.0)
        case .purple: RGBAColor(r: 0.69, g: 0.32, b: 0.87)
        case .pink: RGBAColor(r: 1.0, g: 0.22, b: 0.37)
        case .red: RGBAColor(r: 1.0, g: 0.27, b: 0.23)
        case .orange: RGBAColor(r: 1.0, g: 0.62, b: 0.04)
        case .yellow: RGBAColor(r: 1.0, g: 0.84, b: 0.04)
        case .green: RGBAColor(r: 0.19, g: 0.82, b: 0.35)
        case .white: RGBAColor(r: 1, g: 1, b: 1)
        }
    }
    /// The named colour closest to `c` (projects may hold any colour).
    public static func nearest(_ c: RGBAColor) -> ClickColor {
        allCases.min { a, b in
            func d(_ x: RGBAColor) -> Double { pow(x.r - c.r, 2) + pow(x.g - c.g, 2) + pow(x.b - c.b, 2) }
            return d(a.rgba) < d(b.rgba)
        } ?? .blue
    }
}

public enum ZoomAnimationStyle: String, Codable, CaseIterable, Sendable {
    case slow, smooth, quick, instant
    public var title: String { rawValue.capitalized }
    /// Transition length in seconds.
    public var duration: Double {
        switch self {
        case .slow: 1.1
        case .smooth: 0.75
        case .quick: 0.45
        case .instant: 0
        }
    }
}

public enum ZoomEasing: String, Codable, CaseIterable, Sendable {
    case smooth, linear, snappy
    public var title: String {
        switch self {
        case .smooth: "Ease In & Out"
        case .linear: "Linear"
        case .snappy: "Ease Out"
        }
    }
}

/// A cell of the 3×3 position grid (camera bubble, keystroke label). Raw values of the old 4-corner and
/// top/bottom enums are kept so existing projects decode unchanged.
public enum GridPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    private var index: Int { Self.allCases.firstIndex(of: self) ?? 7 }
    /// 0 = left, 1 = centre, 2 = right.
    public var column: Int { index % 3 }
    /// 0 = top, 1 = middle, 2 = bottom.
    public var row: Int { index / 3 }

    /// Origin (bottom-left, CI space) of an item of `size` placed in `canvas` with margin `m`.
    public func origin(of size: CGSize, in canvas: CGSize, margin m: CGFloat) -> CGPoint {
        let x: CGFloat = [m, (canvas.width - size.width) / 2, canvas.width - m - size.width][column]
        let y: CGFloat = [canvas.height - m - size.height, (canvas.height - size.height) / 2, m][row]
        return CGPoint(x: x, y: y)
    }
}

public enum CameraShape: String, Codable, CaseIterable, Sendable {
    case circle, rounded, square
    public var title: String { rawValue.capitalized }
}

public enum KeystrokeStyle: String, Codable, CaseIterable, Sendable {
    case dark, light
    public var title: String { rawValue.capitalized }
}

// Style structs decode every field with a fallback so projects written by older (or newer) builds still open.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T { (try? decodeIfPresent(T.self, forKey: key)) ?? fallback }
}

public struct CursorSettings: Codable, Hashable, Sendable {
    public var show = true
    /// Multiplier of the natural cursor size.
    public var size = 1.5
    /// 0 = raw movement, 1 = heavily smoothed.
    public var smoothing = 0.6
    public var hideWhenIdle = false
    public var hideWhenTyping = true
    public var clickEffect: ClickEffect = .ripple
    public var clickStyle: ClickStyle = .outline
    /// Shrink the cursor slightly while a button is held.
    public var pressEffect = true
    public var style: CursorStyle = .macOS
    public var rippleColor = ClickColor.blue.rgba
    public init() {}

    /// Values for the "Motion" pair.
    public static let naturalSmoothing = 0.3
    public static let smoothSmoothing = 0.75
    public var isSmoothMotion: Bool { smoothing >= (Self.naturalSmoothing + Self.smoothSmoothing) / 2 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        show = c.value(.show, d.show); size = c.value(.size, d.size); smoothing = c.value(.smoothing, d.smoothing)
        hideWhenIdle = c.value(.hideWhenIdle, d.hideWhenIdle); hideWhenTyping = c.value(.hideWhenTyping, d.hideWhenTyping)
        clickEffect = c.value(.clickEffect, d.clickEffect); clickStyle = c.value(.clickStyle, d.clickStyle)
        pressEffect = c.value(.pressEffect, d.pressEffect); style = c.value(.style, d.style); rippleColor = c.value(.rippleColor, d.rippleColor)
    }
}

public struct ZoomSettings: Codable, Hashable, Sendable {
    public var defaultLevel = 2.0
    public var autoZoom = true
    /// New zooms follow the cursor by default.
    public var followCursorByDefault = false
    public var animation: ZoomAnimationStyle = .smooth
    public var easing: ZoomEasing = .smooth
    /// 0…1 zoom blur applied while a zoom animates.
    public var motionBlur = 0.0
    public init() {}

    /// "Zoom animations: Smooth | Dynamic" presets over (animation, easing).
    public var isDynamic: Bool { animation == .quick || animation == .instant || easing == .snappy }
    public mutating func setDynamic(_ dynamic: Bool) {
        animation = dynamic ? .quick : .smooth
        easing = dynamic ? .snappy : .smooth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        defaultLevel = c.value(.defaultLevel, d.defaultLevel); autoZoom = c.value(.autoZoom, d.autoZoom)
        followCursorByDefault = c.value(.followCursorByDefault, d.followCursorByDefault)
        animation = c.value(.animation, d.animation); easing = c.value(.easing, d.easing); motionBlur = c.value(.motionBlur, d.motionBlur)
    }
}

public struct CameraSettings: Codable, Hashable, Sendable {
    public var show = true
    public var position: GridPosition = .bottomRight
    /// Bubble size as a fraction of the canvas' short side.
    public var size = 0.24
    public var shape: CameraShape = .circle
    public var shrinkOnZoom = true
    public var flip = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        show = c.value(.show, d.show); position = c.value(.position, d.position); size = c.value(.size, d.size)
        shape = c.value(.shape, d.shape); shrinkOnZoom = c.value(.shrinkOnZoom, d.shrinkOnZoom); flip = c.value(.flip, d.flip)
    }
}

public struct KeystrokeSettings: Codable, Hashable, Sendable {
    public var show = false
    public var size = 1.0
    public var style: KeystrokeStyle = .dark
    public var position: GridPosition = .bottom
    /// false = only shortcuts with ⌘ / ⌃ / ⌥.
    public var displayAll = false
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        show = c.value(.show, d.show); size = c.value(.size, d.size); style = c.value(.style, d.style)
        position = c.value(.position, d.position); displayAll = c.value(.displayAll, d.displayAll)
    }
}

public struct AudioSettings: Codable, Hashable, Sendable {
    public var includeMicrophone = true
    public var microphoneVolume = 1.0
    public var includeSystemAudio = true
    public var systemVolume = 1.0
    public init() {}

    private enum LegacyKeys: String, CodingKey { case muted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        let mutedBefore = (try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        includeMicrophone = c.value(.includeMicrophone, d.includeMicrophone && !mutedBefore)
        includeSystemAudio = c.value(.includeSystemAudio, d.includeSystemAudio && !mutedBefore)
        microphoneVolume = c.value(.microphoneVolume, d.microphoneVolume); systemVolume = c.value(.systemVolume, d.systemVolume)
    }

    public var microphoneGain: Float { includeMicrophone ? Float(microphoneVolume) : 0 }
    public var systemGain: Float { includeSystemAudio ? Float(systemVolume) : 0 }
}

/// Every look-and-feel property of a project; the last-used style seeds new projects.
public struct StudioStyle: Codable, Hashable, Sendable {
    public var background: StudioBackground = .gradient(.dusk)
    /// Padding around the recording, fraction of the canvas' short side (0…0.3).
    public var padding = 0.08
    /// Corner radius in pixels at a 1080-pixel canvas (scales with output size), 0…`maxCornerRadius`.
    public var cornerRadius = 18.0
    public static let maxCornerRadius = 60.0
    /// 0…1.
    public var shadow = 0.6
    /// Crop from each edge of the recording, fraction of its short side (0…0.15).
    public var inset = 0.0
    public var aspectRatio: AspectRatio = .auto
    public var cursor = CursorSettings()
    public var zoom = ZoomSettings()
    public var camera = CameraSettings()
    public var keystrokes = KeystrokeSettings()
    public var audio = AudioSettings()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        background = c.value(.background, d.background); padding = c.value(.padding, d.padding)
        cornerRadius = c.value(.cornerRadius, d.cornerRadius); shadow = c.value(.shadow, d.shadow); inset = c.value(.inset, d.inset)
        aspectRatio = c.value(.aspectRatio, d.aspectRatio); cursor = c.value(.cursor, d.cursor); zoom = c.value(.zoom, d.zoom)
        camera = c.value(.camera, d.camera); keystrokes = c.value(.keystrokes, d.keystrokes); audio = c.value(.audio, d.audio)
    }

    /// Effective values (no background ⇒ no padding/corners/shadow).
    public var effectivePadding: Double { background.isNone ? 0 : padding }
    public var effectiveCornerRadius: Double { background.isNone ? 0 : cornerRadius }
    public var effectiveShadow: Double { background.isNone ? 0 : shadow }
}

/// Facts about the recording itself (FLProject.recordingInfo).
public struct RecordingInfo: Codable, Hashable, Sendable {
    /// screen.mov pixel size.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Backing scale of the recorded display.
    public var scale: Double
    public var duration: Double
    public var fps: Int
    public var hasCamera: Bool
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool
    public var recordedAt: Date
    public var cameraName: String?
    public var microphoneName: String?
    public init(pixelWidth: Int, pixelHeight: Int, scale: Double, duration: Double, fps: Int, hasCamera: Bool,
                hasSystemAudio: Bool, hasMicrophone: Bool, recordedAt: Date = Date(), cameraName: String? = nil, microphoneName: String? = nil) {
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.scale = scale; self.duration = duration; self.fps = fps
        self.hasCamera = hasCamera; self.hasSystemAudio = hasSystemAudio; self.hasMicrophone = hasMicrophone
        self.recordedAt = recordedAt; self.cameraName = cameraName; self.microphoneName = microphoneName
    }
    public var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
}

/// project.json
public struct StudioProject: Codable, Hashable, Sendable {
    public var version = 1
    public var title: String
    public var recording: RecordingInfo
    public var clips: [StudioClip]
    public var zooms: [ZoomSegment]
    public var cameraFullscreen: [TimeSegment]
    public var style: StudioStyle

    public init(title: String, recording: RecordingInfo, style: StudioStyle = StudioStyle()) {
        self.title = title; self.recording = recording; self.style = style
        clips = [StudioClip(start: 0, duration: recording.duration)]
        zooms = []
        cameraFullscreen = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, 1)
        title = try c.decode(String.self, forKey: .title)
        recording = try c.decode(RecordingInfo.self, forKey: .recording)
        let clips = c.value(.clips, [StudioClip]()).filter { $0.duration > 0 }
        self.clips = clips.isEmpty ? [StudioClip(start: 0, duration: recording.duration)] : clips
        zooms = c.value(.zooms, [])
        cameraFullscreen = c.value(.cameraFullscreen, [])
        style = c.value(.style, StudioStyle())
    }

    public var timeline: ClipTimeline { ClipTimeline(clips: clips, sourceDuration: recording.duration) }
}

// MARK: - Module defaults

extension Defaults.Keys {
    /// JSON of the last edited `StudioStyle`; new projects start from it.
    static let studioLastStyle = Key<Data?>("studio.lastStyle", default: nil)
    static let studioRecordKeystrokes = Key<Bool>("studio.recordKeystrokes", default: true)
    static let studioExportFormat = Key<String>("studio.export.format", default: "h264")
    static let studioExportResolution = Key<String>("studio.export.resolution", default: "original")
    static let studioExportFPS = Key<Int>("studio.export.fps", default: 60)
    static let studioExportQuality = Key<Double>("studio.export.quality", default: 0.75)
}

enum StudioStyleMemory {
    static var last: StudioStyle {
        guard let data = Defaults[.studioLastStyle], let s = try? JSONDecoder().decode(StudioStyle.self, from: data) else { return StudioStyle() }
        return s
    }
    static func remember(_ style: StudioStyle) {
        var s = style
        // Images inside one package don't exist in others.
        if case .image = s.background { s.background = StudioStyle().background }
        Defaults[.studioLastStyle] = try? JSONEncoder().encode(s)
    }
}
