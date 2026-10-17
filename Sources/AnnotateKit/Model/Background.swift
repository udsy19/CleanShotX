import Foundation
import CoreGraphics
import ShotcraftCore

// MARK: - Settings

public enum BackgroundFill: Codable, Equatable, Sendable {
    case none
    case color(RGBAColor)
    case gradient(String)
    /// The current desktop wallpaper of the screen the editor is on.
    case desktop
    /// A user-chosen image file (path).
    case image(String)
    /// A soft, heavily blurred backdrop ("Blurred" section).
    case blurred(BlurredBackground)

    public var isNone: Bool { if case .none = self { return true } else { return false } }
}

public enum BlurredBackground: String, Codable, CaseIterable, Sendable {
    /// The desktop wallpaper, blurred.
    case wallpaper
    /// Frosted light backdrop.
    case light
    /// Frosted grey backdrop.
    case gray

    public var title: String {
        switch self {
        case .wallpaper: "Blurred Wallpaper"
        case .light: "Blurred Light"
        case .gray: "Blurred Gray"
        }
    }

    /// Soft multi-stop gradient used for the frosted variants (and as the wallpaper fallback).
    var frost: GradientPreset {
        switch self {
        case .wallpaper, .light:
            GradientPreset(id: "blur-light", name: title,
                           colors: [GradientPreset.hex(0xF4F1FA), GradientPreset.hex(0xE3ECF7), GradientPreset.hex(0xF8EDEF)], angle: 135)
        case .gray:
            GradientPreset(id: "blur-gray", name: title,
                           colors: [GradientPreset.hex(0x9EA3AB), GradientPreset.hex(0xC4C8CE), GradientPreset.hex(0x8D929A)], angle: 135)
        }
    }
}

public enum BackgroundAlignment: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    /// Horizontal/vertical factors: 0 = leading/top, 0.5 = centre, 1 = trailing/bottom.
    var factors: (CGFloat, CGFloat) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        }
    }
}

public enum AspectRatio: String, Codable, CaseIterable, Sendable {
    case auto, square, r4x3, r3x2, r16x10, r16x9, r9x16, custom
    public var title: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .r4x3: "4:3"
        case .r3x2: "3:2"
        case .r16x10: "16:10"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        case .custom: "Custom…"
        }
    }
    public var fixedValue: CGFloat? {
        switch self {
        case .auto, .custom: nil
        case .square: 1
        case .r4x3: 4.0 / 3.0
        case .r3x2: 1.5
        case .r16x10: 1.6
        case .r16x9: 16.0 / 9.0
        case .r9x16: 9.0 / 16.0
        }
    }
}

public struct BackgroundSettings: Codable, Equatable, Sendable {
    public var fill: BackgroundFill = .none
    /// Space between the screenshot frame and the output edge (points).
    public var padding: Double = 64
    /// Extra border around the screenshot inside its frame, filled with the image's edge colour (points).
    public var inset: Double = 0
    /// Centre the opaque part of the image (ignore transparent margins such as window shadows).
    public var autoBalance: Bool = true
    public var cornerRadius: Double = 10
    /// 0…1
    public var shadow: Double = 0.5
    public var alignment: BackgroundAlignment = .center
    public var aspect: AspectRatio = .auto
    public var customAspectWidth: Double = 16
    public var customAspectHeight: Double = 9
    /// Downscaled wallpaper image embedded in documents so projects are portable (JPEG).
    public var embeddedImage: Data?

    public init() {}

    public var isActive: Bool { !fill.isNone }

    public var ratio: CGFloat? {
        if aspect == .custom { return customAspectHeight > 0 ? CGFloat(customAspectWidth / customAspectHeight) : nil }
        return aspect.fixedValue
    }

    /// Settings comparison that ignores the embedded image payload (used for preset matching).
    public func sameLook(as o: BackgroundSettings) -> Bool {
        var a = self, b = o
        a.embeddedImage = nil; b.embeddedImage = nil
        return a == b
    }
}

public struct BackgroundPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var settings: BackgroundSettings
    public init(name: String, settings: BackgroundSettings) { self.name = name; self.settings = settings }
}

// MARK: - Gradients

public struct GradientPreset: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let colors: [RGBAColor]
    /// Degrees; 0 = left→right, 90 = top→bottom.
    public let angle: Double

    static func hex(_ v: UInt32) -> RGBAColor {
        RGBAColor(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    /// Original gradient set (20). The first 10 are shown by default, the rest behind "Show more".
    public static let all: [GradientPreset] = [
        .init(id: "dawn", name: "Dawn", colors: [hex(0xFF9A8B), hex(0xFF6A88), hex(0xFF99AC)], angle: 45),
        .init(id: "lagoon", name: "Lagoon", colors: [hex(0x43CBFF), hex(0x9708CC)], angle: 135),
        .init(id: "citrus", name: "Citrus", colors: [hex(0xFDEB71), hex(0xF8D800), hex(0xF79D00)], angle: 120),
        .init(id: "meadow", name: "Meadow", colors: [hex(0x96E6A1), hex(0x3BB78F)], angle: 135),
        .init(id: "dusk", name: "Dusk", colors: [hex(0x2B5876), hex(0x4E4376)], angle: 90),
        .init(id: "berry", name: "Berry", colors: [hex(0xF093FB), hex(0xF5576C)], angle: 135),
        .init(id: "glacier", name: "Glacier", colors: [hex(0xA1C4FD), hex(0xC2E9FB)], angle: 90),
        .init(id: "ember", name: "Ember", colors: [hex(0xF83600), hex(0xF9D423)], angle: 45),
        .init(id: "orchid", name: "Orchid", colors: [hex(0x7F7FD5), hex(0x86A8E7), hex(0x91EAE4)], angle: 120),
        .init(id: "graphite", name: "Graphite", colors: [hex(0x232526), hex(0x414345)], angle: 90),
        .init(id: "peach", name: "Peach", colors: [hex(0xFFECD2), hex(0xFCB69F)], angle: 135),
        .init(id: "aurora", name: "Aurora", colors: [hex(0x00C9A7), hex(0x845EC2)], angle: 160),
        .init(id: "sorbet", name: "Sorbet", colors: [hex(0xFAD0C4), hex(0xFFD1FF)], angle: 90),
        .init(id: "deepsea", name: "Deep Sea", colors: [hex(0x0F2027), hex(0x203A43), hex(0x2C5364)], angle: 135),
        .init(id: "mango", name: "Mango", colors: [hex(0xFFE259), hex(0xFFA751)], angle: 90),
        .init(id: "lavender", name: "Lavender", colors: [hex(0xE0C3FC), hex(0x8EC5FC)], angle: 45),
        .init(id: "forest", name: "Forest", colors: [hex(0x134E5E), hex(0x71B280)], angle: 135),
        .init(id: "flamingo", name: "Flamingo", colors: [hex(0xFF5F6D), hex(0xFFC371)], angle: 120),
        .init(id: "cosmic", name: "Cosmic", colors: [hex(0xFF00CC), hex(0x333399)], angle: 135),
        .init(id: "sky", name: "Sky", colors: [hex(0x56CCF2), hex(0x2F80ED)], angle: 90),
    ]
    public static let defaultVisibleCount = 10

    public static func named(_ id: String) -> GradientPreset? { all.first { $0.id == id } }
}

/// "Plain color" rows: saturated colours, then their pastel versions (each row is followed by a special tile).
public enum BackgroundColors {
    public static let saturated: [RGBAColor] = [
        .black, .white, GradientPreset.hex(0xFF3B30), GradientPreset.hex(0xFF9500),
        GradientPreset.hex(0xFFCC00), GradientPreset.hex(0x34C759), GradientPreset.hex(0x007AFF), GradientPreset.hex(0x8E5CF5),
    ]
    public static let pastel: [RGBAColor] = [
        GradientPreset.hex(0x8E8E93), GradientPreset.hex(0xF2F2F7), GradientPreset.hex(0xFFB3AE), GradientPreset.hex(0xFFD49E),
        GradientPreset.hex(0xFFEBA0), GradientPreset.hex(0xB5EBC3), GradientPreset.hex(0xA8CFFF), GradientPreset.hex(0xD5C4FB),
    ]
    /// Fully transparent fill: padding, corners and shadow without a backdrop.
    public static let transparent = RGBAColor.clear
}

// MARK: - Layout

/// Where everything sits in the final output. All rects are in output points (y-down).
public struct CompositionLayout: Equatable, Sendable {
    public var outputSize: CGSize
    /// The part of document space that is visible (image ∪ objects, or the crop rect).
    public var contentBounds: CGRect
    /// Where `contentBounds` lands in the output.
    public var contentRect: CGRect
    /// `contentRect` grown by the inset — the rounded, shadowed frame.
    public var frameRect: CGRect

    /// Translation from document to output coordinates.
    public var documentToOutput: CGVector {
        CGVector(dx: contentRect.minX - contentBounds.minX, dy: contentRect.minY - contentBounds.minY)
    }

    /// Lays out `contentBounds` on the background. Values are aligned to the pixel grid of `scale` so the
    /// base image is never resampled on export.
    public static func make(contentBounds: CGRect, background b: BackgroundSettings, scale: CGFloat) -> CompositionLayout {
        let content = contentBounds.size
        guard b.isActive else {
            let r = CGRect(origin: .zero, size: content)
            return CompositionLayout(outputSize: content, contentBounds: contentBounds, contentRect: r, frameRect: r)
        }
        let s = max(scale, 1)
        func px(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
        let inset = px(CGFloat(max(0, b.inset)))
        let padding = px(CGFloat(max(0, b.padding)))
        let frame = CGSize(width: content.width + inset * 2, height: content.height + inset * 2)
        var out = CGSize(width: frame.width + padding * 2, height: frame.height + padding * 2)
        if let r = b.ratio, r > 0 {
            if out.width / out.height < r { out.width = out.height * r } else { out.height = out.width / r }
        }
        out = CGSize(width: ceil(out.width * s) / s, height: ceil(out.height * s) / s)
        let (fx, fy) = b.alignment.factors
        let x = px(padding + (out.width - padding * 2 - frame.width) * fx)
        let y = px(padding + (out.height - padding * 2 - frame.height) * fy)
        let frameRect = CGRect(x: x, y: y, width: frame.width, height: frame.height)
        let contentRect = CGRect(x: x + inset, y: y + inset, width: content.width, height: content.height)
        return CompositionLayout(outputSize: out, contentBounds: contentBounds, contentRect: contentRect, frameRect: frameRect)
    }
}

// MARK: - Image analysis

public enum ImageAnalysis {
    /// Bounding box (in pixels, top-left origin) of pixels with alpha above `threshold`. nil if fully transparent.
    public static func opaqueBounds(of image: CGImage, threshold: UInt8 = 8) -> CGRect? {
        if image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst {
            return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = ImageTools.context(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let buf = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        // Row 0 of the bitmap memory is the top row of the image; alpha is the 4th byte (RGBA).
        for y in 0..<h {
            let row = buf + y * bpr
            for x in 0..<w where row[x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Colour of the image's top-left opaque-ish corner (used to fill the background inset).
    public static func cornerColor(of image: CGImage) -> RGBAColor {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        // CGImage cropping uses top-left pixel coordinates.
        guard let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return .white }
        ctx.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let a = Double(px[3]) / 255
        guard a > 0.05 else { return .white }
        return RGBAColor(r: Double(px[0]) / 255 / a, g: Double(px[1]) / 255 / a, b: Double(px[2]) / 255 / a)
    }
}
