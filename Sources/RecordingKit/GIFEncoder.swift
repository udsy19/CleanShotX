import AVFoundation
import ImageIO
import SuperScreenshotCore

public enum GIFError: LocalizedError {
    case cancelled, noVideo, missingSource, encode
    public var errorDescription: String? {
        switch self {
        case .cancelled: "User canceled GIF creation"
        case .noVideo: "The source file does not contain a video track."
        case .missingSource: "The video file could not be found. It may have been moved or deleted."
        case .encode: "An error occurred while processing the video file."
        }
    }
}

/// Video → animated GIF and GIF re-encoding, using ImageIO only.
///
/// Frames are pulled one at a time from `AVAssetImageGenerator` and appended to a `StreamingGIFWriter`, so
/// converting a long recording never holds more than one frame; there is no duration cap, the user can
/// cancel at any time and the partial file is removed.
public enum GIFEncoder {
    /// Encodes `timeRange` of the video at `url` into an infinitely looping GIF.
    /// `progress` is called with 0…1 from a background task. Throws `GIFError.cancelled` on task cancellation.
    public static func convert(video url: URL, to output: URL, timeRange: CMTimeRange? = nil,
                               fps: Int, maxWidth: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> CGSize {
        guard FileManager.default.fileExists(atPath: url.path) else { throw GIFError.missingSource }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GIFError.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let oriented = natural.applying(transform)
        let source = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let target = RecordingMath.fitted(source, maxWidth: maxWidth)

        let full = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let range = timeRange.map { $0.intersection(full) } ?? full
        let times = RecordingMath.gifFrameTimes(duration: range.duration.seconds, fps: fps)
        guard !times.isEmpty else { throw GIFError.noVideo }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = target
        let tolerance = CMTime(seconds: 0.5 / Double(RecordingMath.clampedGIFFPS(fps)), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let delays = RecordingMath.gifFrameDelays(count: times.count, fps: fps)
        let writer = try StreamingGIFWriter(url: output)
        do {
            for (i, t) in times.enumerated() {
                if Task.isCancelled { throw GIFError.cancelled }
                let time = range.start + CMTime(seconds: t, preferredTimescale: 600)
                let image = try await generator.image(at: time).image
                try autoreleasepool { try writer.add(image, delay: delays[i]) }
                progress(Double(i + 1) / Double(times.count))
            }
            if Task.isCancelled { throw GIFError.cancelled }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
        return writer.size
    }

    // MARK: Existing GIFs

    /// A GIF opened for editing. Frames are decoded on demand instead of being held in memory.
    struct Frames {
        let source: CGImageSource
        let delays: [Double]
        var count: Int { delays.count }
        var duration: Double { delays.reduce(0, +) }

        func image(at i: Int) -> CGImage? {
            guard delays.indices.contains(i) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, i, [kCGImageSourceShouldCache: false] as CFDictionary)
        }

        func thumbnail(at i: Int, maxPixelSize: Int) -> CGImage? {
            guard delays.indices.contains(i) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, i, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
        }
    }

    static func loadFrames(_ url: URL) -> Frames? {
        // Read into memory so a later in-place replace of `url` can't pull the file out from under us.
        guard let data = try? Data(contentsOf: url), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let delays = (0..<count).map { i -> Double in
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double).flatMap { $0 > 0 ? $0 : nil }
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 0.1
        }
        return Frames(source: src, delays: delays)
    }

    /// Writes `frames[range]` as a looping GIF.
    static func write(_ frames: Frames, range: ClosedRange<Int>, to url: URL) throws {
        let writer = try StreamingGIFWriter(url: url)
        do {
            for i in range.clamped(to: 0...(frames.count - 1)) {
                try autoreleasepool {
                    guard let image = frames.image(at: i) else { throw GIFError.encode }
                    try writer.add(image, delay: frames.delays[i])
                }
            }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }
}
