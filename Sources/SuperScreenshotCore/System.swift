import AppKit
import AVFoundation
import os

public enum Log {
    public static let app = Logger(subsystem: AppPaths.bundleID, category: "app")
    public static let capture = Logger(subsystem: AppPaths.bundleID, category: "capture")
    public static let recording = Logger(subsystem: AppPaths.bundleID, category: "recording")
    public static let annotate = Logger(subsystem: AppPaths.bundleID, category: "annotate")
    public static let upload = Logger(subsystem: AppPaths.bundleID, category: "upload")
    public static let update = Logger(subsystem: AppPaths.bundleID, category: "update")
}

// MARK: - Sounds (macOS system sounds; no bundled assets)

@MainActor
public enum Sound {
    public enum Effect { case capture, recordStart, recordStop, recordPause, countdownTick, textCopied, uploadDone, exportDone, error }

    private static let systemDir = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static var cache: [String: NSSound] = [:]

    public static func play(_ effect: Effect) {
        guard Defaults[.playSounds] else { return }
        let path: String
        switch effect {
        case .capture:
            switch Defaults[.captureSound] {
            case .none: return
            case .grab: path = systemDir + "Grab.aif"
            case .shutter: path = systemDir + "Shutter.aif"
            case .screenCapture: path = systemDir + "Screen Capture.aif"
            case .pop: path = "/System/Library/Sounds/Pop.aiff"
            case .tink: path = "/System/Library/Sounds/Tink.aiff"
            }
        case .recordStart: path = systemDir + "begin_record.caf"
        case .recordStop: path = systemDir + "end_record.caf"
        case .recordPause: path = systemDir + "media_paused.caf"
        case .countdownTick: path = "/System/Library/Sounds/Tink.aiff"
        case .textCopied: path = "/System/Library/Sounds/Pop.aiff"
        case .uploadDone: path = systemDir + "SentMessage.caf"
        case .exportDone: path = "/System/Library/Sounds/Glass.aiff"
        case .error: path = "/System/Library/Sounds/Basso.aiff"
        }
        let sound = cache[path] ?? NSSound(contentsOfFile: path, byReference: true)
        cache[path] = sound
        sound?.stop()
        sound?.play()
    }
}

// MARK: - Permissions

@MainActor
public enum Permissions {
    public static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    public static var hasAccessibility: Bool { AXIsProcessTrusted() }
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func status(for media: AVMediaType) -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: media) }
    public static func request(_ media: AVMediaType, completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: media) { ok in DispatchQueue.main.async { completion(ok) } }
    }

    public enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture", accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone", camera = "Privacy_Camera", notifications = "Notifications"
    }
    public static func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!)
    }

    /// Ensures screen-recording permission, explaining and opening System Settings if missing.
    public static func ensureScreenRecording() -> Bool {
        if hasScreenRecording { return true }
        if requestScreenRecording() { return true }
        let a = NSAlert()
        a.messageText = "Screen Recording permission required"
        a.informativeText = "In order to continue working properly, Super Screenshot needs Screen Recording permission. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch Super Screenshot."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openSettings(.screenRecording) }
        return false
    }
}

// MARK: - Alerts & HUD

@MainActor
public enum Alerts {
    public static func error(_ message: String, _ error: Error? = nil) {
        Log.app.error("\(message, privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = message
        if let error { a.informativeText = error.localizedDescription }
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Plain informational notice (something happened that the user should know about, nothing to decide).
    public static func info(_ message: String, info: String = "") {
        Log.app.notice("\(message, privacy: .public) \(info, privacy: .public)")
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = message
        a.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Confirmation with optional "Don't ask again" suppression (reset via Settings → Advanced).
    public static func confirm(_ message: String, info: String = "", confirmTitle: String = "OK",
                               cancelTitle: String = "Cancel", destructive: Bool = false, suppressionID: String? = nil) -> Bool {
        if let id = suppressionID, Defaults[.suppressedWarnings].contains(id) { return true }
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        let ok = a.addButton(withTitle: confirmTitle)
        if destructive { ok.hasDestructiveAction = true }
        a.addButton(withTitle: cancelTitle)
        if suppressionID != nil { a.showsSuppressionButton = true; a.suppressionButton?.title = "Don't ask again" }
        NSApp.activate(ignoringOtherApps: true)
        let result = a.runModal() == .alertFirstButtonReturn
        if result, let id = suppressionID, a.suppressionButton?.state == .on { Defaults[.suppressedWarnings].insert(id) }
        return result
    }

    /// Text prompt; returns nil on cancel.
    public static func prompt(title: String, message: String = "", defaultValue: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultValue
        a.accessoryView = field
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? defaultValue : v
    }
}

/// Small translucent toast ("Text has been copied", "Link has been copied"…), centered on the active screen.
@MainActor
public enum HUD {
    private static var window: NSPanel?
    private static var hideWork: DispatchWorkItem?

    public static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.6) {
        hideWork?.cancel()
        window?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 18)
        let fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12
        fx.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        let size = stack.fittingSize
        let screen = NSScreen.active
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.18,
                           width: size.width, height: size.height)
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
        w.level = .statusBar; w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = fx
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 }
        window = w
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 }) { w.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

// MARK: - Screen geometry

public extension NSScreen {
    /// The screen containing the mouse cursor.
    static var active: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    static func with(displayID: CGDirectDisplayID) -> NSScreen? { screens.first { $0.displayID == displayID } }
}

/// Cocoa global coordinates have their origin at the bottom-left of the primary display and grow upward;
/// CoreGraphics/ScreenCaptureKit/window-list coordinates have their origin at the top-left and grow downward.
public enum ScreenGeometry {
    public static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    public static func cgRect(fromCocoa r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    public static func cocoaRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    public static func cgPoint(fromCocoa p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    public static func cocoaPoint(fromCG p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    /// Rect relative to a screen's own top-left, in points (what `SCStreamConfiguration.sourceRect` expects).
    public static func displayLocalRect(_ cocoaRect: CGRect, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: cocoaRect.minX - f.minX, y: f.maxY - cocoaRect.maxY, width: cocoaRect.width, height: cocoaRect.height)
    }

    /// Union of all screen frames.
    public static var desktopFrame: CGRect { NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) } }
}

// MARK: - Dock icon

/// Super Screenshot is a menu-bar (accessory) app; document-style windows (Annotate, Studio, video editor) show the Dock
/// icon while open. Owners register by name; the icon hides when the last owner releases it.
@MainActor
public enum DockIcon {
    private static var owners: [String: Int] = [:]

    /// `owner` identifies the module; `count` is how many of its windows are open.
    public static func set(_ owner: String, count: Int) {
        owners[owner] = count > 0 ? count : nil
        let wanted: NSApplication.ActivationPolicy = owners.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Carries a non-Sendable reference into a `@Sendable` closure when the caller guarantees safe use
/// (e.g. thread-safe AVFoundation objects, or objects only touched on one queue).
public final class UncheckedBox<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}
