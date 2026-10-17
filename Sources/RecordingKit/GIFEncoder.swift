import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import ShotcraftCore

enum GIFError: LocalizedError {
    case cancelled, noVideo, encode
    var errorDescription: String? {
        switch self {
        case .cancelled: "User canceled GIF creation"
        case .noVideo: "The source file does not contain a video track."
        case .encode: "An error occurred while processing the video file."
        }
    }
}

/// Video → animated GIF and GIF re-encoding, using ImageIO only.
enum GIFEncoder {
    /// Encodes `timeRange` of the video at `url` into an infinitely looping GIF.
    /// `progress` is called with 0…1 from a background task. Throws `GIFError.cancelled` on task cancellation.
    static func convert(video url: URL, to output: URL, timeRange: CMTimeRange? = nil,
                        fps: Int, maxWidth: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> CGSize {
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
        try? FileManager.default.removeItem(at: output)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw GIFError.encode
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        var size = target
        for (i, t) in times.enumerated() {
            if Task.isCancelled { throw GIFError.cancelled }
            let time = range.start + CMTime(seconds: t, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            size = CGSize(width: image.width, height: image.height)
            CGImageDestinationAddImage(dest, image, frameProperties(delay: delays[i]))
            progress(Double(i + 1) / Double(times.count))
        }
        if Task.isCancelled { throw GIFError.cancelled }
        guard CGImageDestinationFinalize(dest) else { throw GIFError.encode }
        return size
    }

    static func frameProperties(delay: Double) -> CFDictionary {
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                         kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
    }

    // MARK: Existing GIFs

    struct Frames {
        var images: [CGImage]
        var delays: [Double]
        var duration: Double { delays.reduce(0, +) }
    }

    static func loadFrames(_ url: URL) -> Frames? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var images: [CGImage] = [], delays: [Double] = []
        for i in 0..<CGImageSourceGetCount(src) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double).flatMap { $0 > 0 ? $0 : nil }
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            images.append(img)
            delays.append(d)
        }
        return images.isEmpty ? nil : Frames(images: images, delays: delays)
    }

    /// Writes `frames[range]` as a looping GIF.
    static func write(_ frames: Frames, range: ClosedRange<Int>, to url: URL) throws {
        let indices = Array(range.clamped(to: 0...(frames.images.count - 1)))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, indices.count, nil) else {
            throw GIFError.encode
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in indices { CGImageDestinationAddImage(dest, frames.images[i], frameProperties(delay: frames.delays[i])) }
        guard CGImageDestinationFinalize(dest) else { throw GIFError.encode }
    }
}
