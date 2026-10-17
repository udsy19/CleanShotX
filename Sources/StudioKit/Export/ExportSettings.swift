import Foundation
import CoreGraphics

/// Export options chosen in the export panel (FLExportPanel).
public struct ExportSettings: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        case h264, hevc, gif
        public var title: String {
            switch self {
            case .h264: "MP4 (H.264)"
            case .hevc: "MP4 (HEVC)"
            case .gif: "GIF"
            }
        }
        public var fileExtension: String { self == .gif ? "gif" : "mp4" }
    }

    public enum Resolution: String, CaseIterable, Sendable {
        case original, uhd4k, qhd1440, fhd1080, hd720, sd480, p360, p240
        public var title: String {
            switch self {
            case .original: "Original"
            case .uhd4k: "4k"
            case .qhd1440: "1440p"
            case .fhd1080: "1080p"
            case .hd720: "720p"
            case .sd480: "480p"
            case .p360: "360p"
            case .p240: "240p"
            }
        }
        /// Short side in pixels.
        public var shortSide: Double? {
            switch self {
            case .original: nil
            case .uhd4k: 2160
            case .qhd1440: 1440
            case .fhd1080: 1080
            case .hd720: 720
            case .sd480: 480
            case .p360: 360
            case .p240: 240
            }
        }
        /// Presets offered for a canvas: never upscale past the original.
        public static func options(for base: CGSize) -> [Resolution] {
            let short = Double(min(base.width, base.height))
            return allCases.filter { $0.shortSide.map { $0 < short - 0.5 } ?? true }
        }
    }

    public var format: Format = .h264
    public var resolution: Resolution = .original
    public var fps = 60
    /// 0…1.
    public var quality = 0.75
    public var includeAudio = true
    public var gifFPS = 15

    public init() {}

    public var effectiveFPS: Int { format == .gif ? gifFPS : fps }

    /// "Very low" … "High" label for the quality slider.
    public static func qualityTitle(_ q: Double) -> String {
        switch q {
        case ..<0.25: "Very low"
        case ..<0.5: "Low"
        case ..<0.75: "Medium"
        default: "High"
        }
    }

    /// Output pixel size for a base canvas.
    public func outputSize(base: CGSize) -> CGSize {
        var short = resolution.shortSide
        if format == .gif { short = min(short ?? Double(min(base.width, base.height)), 720) }
        var size = CanvasLayout.scaled(base, shortSide: short)
        // H.264 hardware encoders top out at 4096×2304.
        if format == .h264 && (size.width > 4096 || size.height > 4096) {
            size = CanvasLayout.fitted(size, within: CGSize(width: 4096, height: 4096))
        }
        return size
    }
}

/// File-size estimate shown in the export panel (FLEncoderEstimateCalculator).
public enum EncoderEstimate {
    /// Average video bitrate (bits/s).
    public static func videoBitrate(size: CGSize, fps: Int, quality: Double, format: ExportSettings.Format) -> Int {
        let q = min(max(quality, 0), 1)
        // Bits per pixel per frame; screen content compresses well, so this stays low.
        var bpp = 0.03 + 0.17 * q * q
        if format == .hevc { bpp *= 0.65 }
        let fpsFactor = pow(Double(max(fps, 1)) / 30, 0.75) * 30   // higher frame rates cost less than linearly
        return max(800_000, Int(Double(size.width * size.height) * fpsFactor * bpp))
    }

    public static let audioBitrate = 192_000

    public static func estimatedBytes(settings: ExportSettings, base: CGSize, duration: Double, hasAudio: Bool) -> Int64 {
        let size = settings.outputSize(base: base)
        if settings.format == .gif {
            // Palette frames, LZW over mostly-static screen content.
            let perFrame = Double(size.width * size.height) * 0.12
            return Int64(perFrame * Double(settings.gifFPS) * duration)
        }
        var bits = Double(videoBitrate(size: size, fps: settings.effectiveFPS, quality: settings.quality, format: settings.format)) * duration
        if hasAudio && settings.includeAudio { bits += Double(audioBitrate) * duration }
        return Int64(bits / 8)
    }
}
