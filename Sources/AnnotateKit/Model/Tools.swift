import Foundation
import CoreGraphics
import ShotcraftCore

/// Editor tools in toolbar order.
public enum AnnotateTool: String, Codable, CaseIterable, Sendable {
    case select, crop, rectangle, filledRectangle, ellipse, line, arrow, text, pen, highlighter, pixelate, spotlight, counter

    public var title: String {
        switch self {
        case .select: "Move"
        case .crop: "Crop & Resize"
        case .rectangle: "Rectangle"
        case .filledRectangle: "Filled Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .pixelate: "Pixelate"
        case .spotlight: "Spotlight"
        case .counter: "Counter"
        }
    }

    /// Single-key shortcut (no modifiers).
    public var key: Character {
        switch self {
        case .select: "v"
        case .crop: "c"
        case .rectangle: "r"
        case .filledRectangle: "f"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .pen: "p"
        case .highlighter: "h"
        case .pixelate: "b"
        case .spotlight: "s"
        case .counter: "n"
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .rectangle: "rectangle"
        case .filledRectangle: "rectangle.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .pixelate: "checkerboard.rectangle"
        case .spotlight: "light.max"
        case .counter: "1.circle"
        }
    }

    /// The object kind this tool creates.
    public var kind: AnnotationKind? {
        switch self {
        case .select, .crop: nil
        case .rectangle: .rectangle
        case .filledRectangle: .filledRectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .text: .text
        case .pen: .pen
        case .highlighter: .highlighter
        case .pixelate: .pixelate
        case .spotlight: .spotlight
        case .counter: .counter
        }
    }

    public static func forKind(_ k: AnnotationKind) -> AnnotateTool {
        allCases.first { $0.kind == k } ?? .select
    }

    public static func forKey(_ c: Character) -> AnnotateTool? { allCases.first { $0.key == c } }
}

/// Per-tool remembered style (CleanShot: annotateLastArrowStyle, annotateLastTextSize, …).
public struct ToolStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    public var lineWidth: CGFloat = 4
    public var arrowStyle: ArrowStyle = .standard
    public var textStyle: TextStyle = .standard
    public var fontSize: CGFloat = 24
    public var pixelateStyle: PixelateStyle = .pixelate
    public var intensity: Double = 0.5
    public var spotlightShape: SpotlightShape = .rectangle
    public var counterStyle: CounterStyle = .numbers
    public var counterSize: CGFloat = 32
    public var highlightShape: HighlightShape = .freehand
    public var highlightOpacity: Double = 0.45

    public init(color: RGBAColor) { self.color = color }

    public static func defaults(for tool: AnnotateTool) -> ToolStyle {
        var s = ToolStyle(color: ColorPalette.presets[0].color)
        switch tool {
        case .highlighter: s.color = ColorPalette.named("Yellow"); s.lineWidth = 6
        case .filledRectangle: s.color = ColorPalette.named("Black")
        case .text: s.lineWidth = 2
        case .pen: s.lineWidth = 3
        default: break
        }
        return s
    }

    /// Thickness presets offered in the width menu.
    public static let widths: [CGFloat] = [1, 2, 3, 4, 6, 8, 12, 16, 24]
    public static let fontSizes: [CGFloat] = [12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 80, 96]
    public static let counterSizes: [CGFloat] = [20, 24, 28, 32, 40, 48, 64]
}

// MARK: - Palette

public struct NamedColor: Sendable {
    public let name: String
    public let color: RGBAColor
}

public enum ColorPalette {
    static func c(_ hex: UInt32) -> RGBAColor { GradientPreset.hex(hex) }
    public static let presets: [NamedColor] = [
        NamedColor(name: "Red", color: c(0xFF3B30)),
        NamedColor(name: "Orange", color: c(0xFF9500)),
        NamedColor(name: "Yellow", color: c(0xFFD60A)),
        NamedColor(name: "Green", color: c(0x34C759)),
        NamedColor(name: "Teal", color: c(0x30B0C7)),
        NamedColor(name: "Blue", color: c(0x0A84FF)),
        NamedColor(name: "Indigo", color: c(0x5E5CE6)),
        NamedColor(name: "Purple", color: c(0xBF5AF2)),
        NamedColor(name: "Pink", color: c(0xFF2D92)),
        NamedColor(name: "Brown", color: c(0xA2845E)),
        NamedColor(name: "Gray", color: c(0x8E8E93)),
        NamedColor(name: "Black", color: c(0x000000)),
        NamedColor(name: "White", color: c(0xFFFFFF)),
    ]
    public static func named(_ n: String) -> RGBAColor { presets.first { $0.name == n }?.color ?? .black }

    public static func name(of color: RGBAColor) -> String? {
        presets.first { $0.color.isClose(to: color) }?.name
    }
}

extension RGBAColor {
    func isClose(to o: RGBAColor, tolerance: Double = 0.004) -> Bool {
        abs(r - o.r) < tolerance && abs(g - o.g) < tolerance && abs(b - o.b) < tolerance && abs(a - o.a) < tolerance
    }
    /// Relative luminance (sRGB approximation).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    /// Black or white, whichever reads better on top of this colour.
    var contrasting: RGBAColor { luminance > 0.62 ? .black : .white }
    func withAlpha(_ a: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: a) }
}

// MARK: - Module-private settings

extension Defaults.Keys {
    static let annotateToolStyles = Key<[String: ToolStyle]>("annotate.toolStyles", default: [:])
    static let annotateLastTool = Key<String>("annotate.lastTool", default: AnnotateTool.arrow.rawValue)
    static let annotateCustomColors = Key<[RGBAColor]>("annotate.customColors", default: [])
    static let annotateBackgroundPresets = Key<[BackgroundPreset]>("annotate.backgroundPresets", default: [])
    static let annotateLastBackground = Key<BackgroundSettings?>("annotate.lastBackground", default: nil)
    static let annotateBackgroundToolOpen = Key<Bool>("annotate.backgroundToolOpen", default: false)
    static let annotateShowAllGradients = Key<Bool>("annotate.showAllGradients", default: false)
    static let annotateRecentProjects = Key<[String]>("annotate.recentProjects", default: [])
    static let annotateLastSaveFormat = Key<String>("annotate.lastSaveFormat", default: "png")
    static let annotatePrintFitToPage = Key<Bool>("annotate.printFitToPage", default: true)
}

/// Recently opened/saved `.shotcraft` projects (CleanShot: `AnnotateController.projectsHistory`).
public enum RecentProjects {
    public static let limit = 15

    public static var urls: [URL] {
        Defaults[.annotateRecentProjects].map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func add(_ url: URL) {
        Defaults[.annotateRecentProjects] = updated(Defaults[.annotateRecentProjects], adding: url.path)
    }

    public static func clear() { Defaults[.annotateRecentProjects] = [] }

    /// Pure list update: newest first, de-duplicated, capped.
    public static func updated(_ list: [String], adding path: String, limit: Int = limit) -> [String] {
        Array(([path] + list.filter { $0 != path }).prefix(limit))
    }
}
