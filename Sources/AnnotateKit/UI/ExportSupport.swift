import AppKit
import UniformTypeIdentifiers
import ShotcraftCore

// MARK: - Drag me

/// "Drag me" handle in the bottom bar (CleanShot `ANDragButton`): drags the flattened image out as a file.
@MainActor
final class DragHandleView: NSView, NSDraggingSource {
    /// Writes the flattened image to a temporary file and returns it (nil = nothing to drag).
    var fileProvider: (() -> URL?)?
    private var downEvent: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        func grip() -> NSImageView {
            let v = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage())
            v.symbolConfiguration = .init(pointSize: 10, weight: .medium)
            v.contentTintColor = .tertiaryLabelColor
            return v
        }
        let label = UI.label("Drag me", size: 12, color: .labelColor)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [grip(), label, grip()])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        toolTip = "Drag the annotated image into another app or Finder"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag the annotated image")
    }

    /// Raised pill (white in light mode, control grey in dark mode).
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 1)
        let pill = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.set()
        NSColor.controlColor.setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        pill.lineWidth = 0.5
        pill.stroke()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let d = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard d > 3, let url = fileProvider?() else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        let side: CGFloat = 96
        let aspect = icon.size.height > 0 ? icon.size.width / icon.size.height : 1
        let size = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

// MARK: - Printing

/// Image view used for printing (CleanShot `ImagePrinter` + `MultiPageImageView`).
final class PrintImageView: NSView {
    private let image: CGImage

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
    }
}

/// Print panel accessory with "Scale image to fit on one page" (CleanShot `CSPrintAccessoryViewController`).
@MainActor
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    private let printInfo: NSPrintInfo

    @objc dynamic var fitToPage: Bool {
        didSet {
            Defaults[.annotatePrintFitToPage] = fitToPage
            Self.apply(fitToPage, to: printInfo)
        }
    }

    init(printInfo: NSPrintInfo) {
        self.printInfo = printInfo
        self.fitToPage = Defaults[.annotatePrintFitToPage]
        super.init(nibName: nil, bundle: nil)
        Self.apply(fitToPage, to: printInfo)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func apply(_ fit: Bool, to info: NSPrintInfo) {
        info.horizontalPagination = fit ? .fit : .automatic
        info.verticalPagination = fit ? .fit : .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
    }

    override func loadView() {
        let box = NSButton(checkboxWithTitle: "Scale image to fit on one page", target: nil, action: nil)
        box.state = fitToPage ? .on : .off
        box.onAction { [weak self] s in self?.fitToPage = (s as? NSButton)?.state == .on }
        let stack = NSStackView(views: [box])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        view = stack
    }

    nonisolated func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let fit = MainActor.assumeIsolated { fitToPage }
        return [[.itemName: "Scale image to fit on one page", .itemDescription: fit ? "On" : "Off"]]
    }

    nonisolated func keyPathsForValuesAffectingPreview() -> Set<String> { ["fitToPage"] }
}

@MainActor
enum ImagePrinter {
    static func print(_ image: CGImage, scale: CGFloat, title: String, window: NSWindow?) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = image.width > image.height ? .landscape : .portrait
        let view = PrintImageView(image: image, scale: scale)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        let accessory = PrintAccessoryController(printInfo: info)
        op.printPanel.addAccessoryController(accessory)
        op.printPanel.options.insert([.showsPreview, .showsOrientation, .showsPaperSize, .showsScaling])
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}

// MARK: - Save panel format popup

/// Formats offered by Save As.
enum ExportFormat: CaseIterable {
    case png, jpeg, heic, tiff, project

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .project: "Shotcraft Project"
        }
    }
    var imageFormat: ImageFormat? {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .project: nil
        }
    }
    var fileExtension: String { imageFormat?.fileExtension ?? ShotcraftDocument.fileExtension }
    var contentType: UTType {
        if let f = imageFormat { return UTType(f.utType) ?? .png }
        return AnnotateService.projectType
    }
    static func from(_ key: String) -> ExportFormat {
        allCases.first { $0.fileExtension == key || $0.imageFormat?.rawValue == key } ?? .png
    }
}

extension ImageFormat {
    /// Format matching a file extension (jpg/jpeg/png/heic/tiff), nil if unknown.
    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "heic": self = .heic
        case "tif", "tiff": self = .tiff
        default: return nil
        }
    }
}
