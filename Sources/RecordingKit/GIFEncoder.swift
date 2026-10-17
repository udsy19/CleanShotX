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

/// Writes an animated GIF one frame at a time, so memory stays flat however long the GIF is.
///
/// A multi-frame `CGImageDestination` keeps every frame until `Finalize` and then needs several GB for a
/// minute of 1280-px video. Here each frame is quantized and LZW-compressed by ImageIO as a single-frame
/// GIF, and its image blocks are spliced into the output with a local colour table and our own delay.
public final class StreamingGIFWriter {
    private let url: URL
    private var handle: FileHandle?
    public private(set) var frameCount = 0
    public private(set) var size: CGSize = .zero

    public init(url: URL) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { throw GIFError.encode }
        handle = h
    }

    deinit { try? handle?.close() }

    /// Appends a frame shown for `delay` seconds. The first frame fixes the canvas size.
    public func add(_ image: CGImage, delay: Double) throws {
        guard let handle else { throw GIFError.encode }
        if frameCount == 0 {
            size = CGSize(width: image.width, height: image.height)
            var header = Array("GIF89a".utf8)
            header += le16(image.width) + le16(image.height) + [0, 0, 0]   // no global colour table
            header += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]   // loop forever
            try handle.write(contentsOf: Data(header))
        }
        let single = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(single, UTType.gif.identifier as CFString, 1, nil) else {
            throw GIFError.encode
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw GIFError.encode }
        let blocks = try Self.frameBlocks(fromSingleFrameGIF: [UInt8](single as Data),
                                          delayCentiseconds: RecordingMath.gifDelayCentiseconds(delay))
        try handle.write(contentsOf: Data(blocks))
        frameCount += 1
    }

    /// Writes the trailer and closes the file.
    public func finish() throws {
        guard let handle, frameCount > 0 else { abort(); throw GIFError.encode }
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
        self.handle = nil
    }

    /// Closes and deletes the partial file.
    public func abort() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    /// Graphic Control Extension + image descriptor (with a local colour table) + image data of the first
    /// frame in a single-frame GIF.
    static func frameBlocks(fromSingleFrameGIF d: [UInt8], delayCentiseconds cs: Int) throws -> [UInt8] {
        func need(_ end: Int) throws { if end > d.count { throw GIFError.encode } }
        func skipSubBlocks(_ start: Int) throws -> Int {
            var i = start
            while true {
                try need(i + 1)
                let n = Int(d[i]); i += 1
                if n == 0 { return i }
                i += n
            }
        }
        try need(13)
        guard d[0] == 0x47, d[1] == 0x49, d[2] == 0x46 else { throw GIFError.encode }   // "GIF"
        var i = 13
        var globalTable: [UInt8] = []
        var globalBits: UInt8 = 0
        if d[10] & 0x80 != 0 {
            globalBits = d[10] & 0x07
            let n = 3 * (1 << (Int(globalBits) + 1))
            try need(i + n)
            globalTable = Array(d[i..<i + n]); i += n
        }
        var transparentIndex: UInt8?
        while i < d.count {
            switch d[i] {
            case 0x21:   // extension
                try need(i + 2)
                let label = d[i + 1]
                i += 2
                if label == 0xF9 {
                    try need(i + 5)
                    if d[i] == 4, d[i + 1] & 0x01 != 0 { transparentIndex = d[i + 4] }
                }
                i = try skipSubBlocks(i)
            case 0x2C:   // image descriptor
                try need(i + 10)
                var descriptor = Array(d[i..<i + 10])
                var j = i + 10
                var table: [UInt8]
                if descriptor[9] & 0x80 != 0 {
                    let n = 3 * (1 << (Int(descriptor[9] & 0x07) + 1))
                    try need(j + n)
                    table = Array(d[j..<j + n]); j += n
                } else {
                    guard !globalTable.isEmpty else { throw GIFError.encode }
                    table = globalTable
                    descriptor[9] = 0x80 | (descriptor[9] & 0x40) | globalBits   // keep the interlace flag
                }
                try need(j + 1)
                let end = try skipSubBlocks(j + 1)   // LZW minimum code size, then data sub-blocks
                // Disposal 1 (keep) for opaque frames; 2 (restore background) when the frame has transparency.
                let packed: UInt8 = transparentIndex == nil ? 0x04 : 0x09
                let delay = min(0xFFFF, max(0, cs))
                var out: [UInt8] = [0x21, 0xF9, 0x04, packed, UInt8(delay & 0xFF), UInt8(delay >> 8), transparentIndex ?? 0, 0]
                out += descriptor
                out += table
                out += d[j..<end]
                return out
            default:
                throw GIFError.encode
            }
        }
        throw GIFError.encode
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
