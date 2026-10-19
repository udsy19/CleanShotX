import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GIFWriteError: LocalizedError {
    case encode, destinationIsFolder(String)
    public var errorDescription: String? {
        switch self {
        case .encode: "An error occurred while processing the video file."
        case .destinationIsFolder(let name): "Cannot save to “\(name)”: a folder with that name is in the way."
        }
    }
}

/// Writes an animated GIF one frame at a time, so memory stays flat however long the GIF is.
///
/// A multi-frame `CGImageDestination` keeps every frame until `Finalize` and then needs several GB for a
/// minute of 1280-px video. Here each frame is quantized and LZW-compressed by ImageIO as a single-frame
/// GIF, and its image blocks are spliced into the output with a local colour table and our own delay.
/// Shared by the recording GIF converter, the GIF trimmer and Studio's GIF export.
public final class StreamingGIFWriter {
    private let url: URL
    private var handle: FileHandle?
    public private(set) var frameCount = 0
    public private(set) var size: CGSize = .zero

    /// Replaces any file at `url`; throws the system's reason when the location is not writable, and never
    /// removes a folder that happens to be in the way.
    public init(url: URL) throws {
        self.url = url
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            throw GIFWriteError.destinationIsFolder(url.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: url)
        try Data().write(to: url)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle?.close() }

    /// GIF delay field value (centiseconds, ≥ 2): browsers clamp anything below 2 cs.
    public static func delayCentiseconds(_ seconds: Double) -> Int { max(2, Int((seconds * 100).rounded())) }

    /// Appends a frame shown for `delay` seconds. The first frame fixes the canvas size.
    public func add(_ image: CGImage, delay: Double) throws {
        guard let handle else { throw GIFWriteError.encode }
        if frameCount == 0 {
            size = CGSize(width: image.width, height: image.height)
            var header = Array("GIF89a".utf8)
            header += le16(image.width) + le16(image.height) + [0, 0, 0]   // no global colour table
            header += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]   // loop forever
            try handle.write(contentsOf: Data(header))
        }
        let single = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(single, UTType.gif.identifier as CFString, 1, nil) else {
            throw GIFWriteError.encode
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw GIFWriteError.encode }
        let blocks = try Self.frameBlocks(fromSingleFrameGIF: [UInt8](single as Data), delayCentiseconds: Self.delayCentiseconds(delay))
        try handle.write(contentsOf: Data(blocks))
        frameCount += 1
    }

    /// Writes the trailer and closes the file.
    public func finish() throws {
        guard let handle, frameCount > 0 else { abort(); throw GIFWriteError.encode }
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
        func need(_ end: Int) throws { if end > d.count { throw GIFWriteError.encode } }
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
        guard d[0] == 0x47, d[1] == 0x49, d[2] == 0x46 else { throw GIFWriteError.encode }   // "GIF"
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
                    guard !globalTable.isEmpty else { throw GIFWriteError.encode }
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
                throw GIFWriteError.encode
            }
        }
        throw GIFWriteError.encode
    }
}
