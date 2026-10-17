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
        case original, uhd4k, fhd1080, hd720, sd480
        public var title: String {
            switch self {
            case .original: "Original"
            case .uhd4k: "4K"
            case .fhd1080: "1080p"
            case .hd720: "720p"
            case .sd480: "480p"
            }
        }
        /// Short side in pixels.
        public var shortSide: Double? {
            switch self {
            case .original: nil
            case .uhd4k: 2160
            case .fhd1080: 1080
            case .hd720: 720
            case .sd480: 480
            }
        }
    }

    public var format: Format = .h264
    public var resolution: Resolution = .original
    public var fps = 60
    /// 0…1.
    public var quality = 0.75
    /// Balanced bitrate, ≤1080p, H.264 — small files that stream quickly.
    public var optimizedForSharing = false
    public var includeAudio = true
    public var gifFPS = 15

    public init() {}

    public var effectiveFormat: Format { optimizedForSharing && format != .gif ? .h264 : format }
    public var effectiveFPS: Int { format == .gif ? gifFPS : (optimizedForSharing ? min(fps, 30) : fps) }

    /// Output pixel size for a base canvas.
    public func outputSize(base: CGSize) -> CGSize {
        var short = resolution.shortSide
        if optimizedForSharing || format == .gif {
            let cap: Double = format == .gif ? 720 : 1080
            short = min(short ?? Double(min(base.width, base.height)), cap)
        }
        var size = CanvasLayout.scaled(base, shortSide: short)
        // H.264 hardware encoders top out at 4096×2304.
        if effectiveFormat == .h264 && (size.width > 4096 || size.height > 4096) {
            size = CanvasLayout.fitted(size, within: CGSize(width: 4096, height: 4096))
        }
        return size
    }
}

/// File-size estimate shown in the export panel (FLEncoderEstimateCalculator).
public enum EncoderEstimate {
    /// Average video bitrate (bits/s).
    public static func videoBitrate(size: CGSize, fps: Int, quality: Double, format: ExportSettings.Format, optimized: Bool) -> Int {
        let q = min(max(quality, 0), 1)
        // Bits per pixel per frame; screen content compresses well, so this stays low.
        var bpp = optimized ? 0.05 : 0.03 + 0.17 * q * q
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
        var bits = Double(videoBitrate(size: size, fps: settings.effectiveFPS, quality: settings.quality,
                                       format: settings.effectiveFormat, optimized: settings.optimizedForSharing)) * duration
        if hasAudio && settings.includeAudio { bits += Double(audioBitrate) * duration }
        return Int64(bits / 8)
    }
}
