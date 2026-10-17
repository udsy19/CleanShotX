import Foundation
import CoreGraphics
import ImageIO
import ShotcraftCore

/// Everything that makes up an Annotate document. A value: the undo history stores whole snapshots
/// (CGImage and Data are reference-backed, so snapshots are cheap).
public struct CanvasState {
    /// Base screenshot pixels.
    public var image: CGImage
    /// Pixels per document point (2 for Retina captures).
    public var scale: CGFloat
    public var objects: [Annotation] = []
    /// Non-destructive crop in document points.
    public var cropRect: CGRect?
    public var background = BackgroundSettings()
    /// Darkness of the area outside spotlights (0…1).
    public var spotlightOpacity: Double = 0.55
    /// First counter number.
    public var counterStart: Int = 1

    public init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(scale, 1)
    }

    public var imageSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    public var imageRect: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// The visible part of document space.
    /// - Parameters:
    ///   - expand: grow to include every object ("Ensures all annotations fit by dynamically resizing canvas").
    ///   - opaqueBounds: opaque region of the image in pixels (used when the background auto-balances).
    public func contentBounds(expand: Bool, opaqueBounds: CGRect? = nil) -> CGRect {
        if let c = cropRect, c.width >= 1, c.height >= 1 { return Geo.pixelAligned(c, scale: scale) }
        var r = imageRect
        if background.isActive, background.autoBalance, let o = opaqueBounds, o.width > 0, o.height > 0 {
            r = CGRect(x: o.minX / scale, y: o.minY / scale, width: o.width / scale, height: o.height / scale)
        }
        if expand {
            for o in objects where o.kind != .spotlight { r = r.union(o.visualBounds) }
        }
        return Geo.pixelAligned(r, scale: scale)
    }

    /// Final composition layout (content bounds placed on the background).
    public func layout(expand: Bool, opaqueBounds: CGRect?) -> CompositionLayout {
        let balance = background.isActive && background.autoBalance ? opaqueBounds : nil
        return CompositionLayout.make(contentBounds: contentBounds(expand: expand, opaqueBounds: balance),
                                      background: background, scale: scale)
    }

    /// True when both states would render identically (used to decide whether an interaction is undoable).
    public func isSameContent(as o: CanvasState) -> Bool {
        image === o.image && scale == o.scale && objects == o.objects && cropRect == o.cropRect &&
            background == o.background && spotlightOpacity == o.spotlightOpacity && counterStart == o.counterStart
    }
}

// MARK: - Undo

/// Snapshot-based undo/redo stack (CleanShot: `AnnotateHistory(historyPoints, currentHistoryIndex)`).
public struct UndoStack<State> {
    public private(set) var undoStates: [State] = []
    public private(set) var redoStates: [State] = []
    public let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }

    /// Records the state *before* a change.
    public mutating func record(_ before: State) {
        undoStates.append(before)
        if undoStates.count > limit { undoStates.removeFirst(undoStates.count - limit) }
        redoStates.removeAll()
    }

    /// Returns the state to restore; `current` becomes redoable.
    public mutating func undo(current: State) -> State? {
        guard let s = undoStates.popLast() else { return nil }
        redoStates.append(current)
        return s
    }

    public mutating func redo(current: State) -> State? {
        guard let s = redoStates.popLast() else { return nil }
        undoStates.append(current)
        return s
    }
}

// MARK: - .shotcraft documents

/// `.shotcraft` project files: a single JSON document with the PNG base image embedded (base64).
public enum ShotcraftDocument {
    public static let typeIdentifier = "com.udsy.shotcraft.document"
    public static let fileExtension = "shotcraft"
    public static let currentVersion = 1

    public enum DocumentError: LocalizedError {
        case notAProject, newerVersion(Int), badImage, encodeFailed
        public var errorDescription: String? {
            switch self {
            case .notAProject: "The file isn't a Shotcraft project."
            case .newerVersion(let v): "The project was created by a newer version of Shotcraft (format \(v))."
            case .badImage: "The project's image data is damaged."
            case .encodeFailed: "The image couldn't be encoded."
            }
        }
    }

    struct ImageBlob: Codable {
        var scale: CGFloat
        var png: Data
    }

    struct File: Codable {
        var format: String
        var version: Int
        var createdAt: Date
        var modifiedAt: Date
        var sourcePath: String?
        var image: ImageBlob
        var cropRect: CGRect?
        var background: BackgroundSettings
        var spotlightOpacity: Double
        var counterStart: Int
        var objects: [Annotation]
        /// Flattened rendering (≤1024 px) for Quick Look previews/thumbnails; ignored when opening.
        var preview: Data?
    }

    public struct Loaded {
        public var state: CanvasState
        public var sourceURL: URL?
        public var createdAt: Date
    }

    public static func encode(_ state: CanvasState, sourceURL: URL?, createdAt: Date = Date()) throws -> Data {
        guard let png = ImageTools.pngData(state.image) else { throw DocumentError.encodeFailed }
        let file = File(format: typeIdentifier, version: currentVersion, createdAt: createdAt, modifiedAt: Date(),
                        sourcePath: sourceURL?.path, image: ImageBlob(scale: state.scale, png: png),
                        cropRect: state.cropRect, background: state.background,
                        spotlightOpacity: state.spotlightOpacity, counterStart: state.counterStart, objects: state.objects,
                        preview: previewPNG(state))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(file)
    }

    private static func previewPNG(_ state: CanvasState) -> Data? {
        guard let full = AnnotateComposer.render(state, expandCanvas: Defaults[.annotateExpandCanvas]) else { return nil }
        let longest = CGFloat(max(full.width, full.height))
        let img = longest > 1024 ? ImageTools.resized(full, factor: 1024 / longest) : full
        return ImageTools.pngData(img)
    }

    public static func decode(_ data: Data) throws -> Loaded {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // Peek at the header first so a newer format gives a helpful error instead of a decoding failure.
        struct Header: Decodable { var format: String?; var version: Int? }
        guard let header = try? dec.decode(Header.self, from: data), header.format == typeIdentifier else {
            throw DocumentError.notAProject
        }
        if let v = header.version, v > currentVersion { throw DocumentError.newerVersion(v) }
        let file = try dec.decode(File.self, from: data)
        guard let src = CGImageSourceCreateWithData(file.image.png as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw DocumentError.badImage }
        var state = CanvasState(image: img, scale: file.image.scale)
        state.objects = file.objects
        state.cropRect = file.cropRect
        state.background = file.background
        state.spotlightOpacity = file.spotlightOpacity
        state.counterStart = file.counterStart
        return Loaded(state: state, sourceURL: file.sourcePath.map { URL(fileURLWithPath: $0) }, createdAt: file.createdAt)
    }
}
