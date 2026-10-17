import Foundation
import AppKit
import Carbon.HIToolbox

/// Every command the app can perform from the menu bar, a global shortcut or the URL scheme.
public enum AppAction: String, Codable, CaseIterable, Sendable {
    case allInOne
    case captureArea, capturePreviousArea, captureFullscreen, captureWindow, selfTimer
    case captureAreaAndCopy, captureAreaAndSave, captureAreaAndAnnotate, captureAreaAndUpload, captureAreaAndPin
    case scrollingCapture
    case captureText
    case recordScreen, recordGIF, recordStudio
    case toggleDesktopIcons
    case openAnnotate, openFromClipboard, annotateLast
    case pinScreenshot, pinLast, togglePins, closeAllOverlays
    case openHistory, restoreLastCapture
    case colorPicker
    case openPreferences

    public var title: String {
        switch self {
        case .allInOne: "All-In-One"
        case .captureArea: "Capture Area"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureWindow: "Capture Window"
        case .selfTimer: "Self-Timer"
        case .captureAreaAndCopy: "Capture Area & Copy to Clipboard"
        case .captureAreaAndSave: "Capture Area & Save"
        case .captureAreaAndAnnotate: "Capture Area & Annotate"
        case .captureAreaAndUpload: "Capture Area & Upload"
        case .captureAreaAndPin: "Capture Area & Pin to the Screen"
        case .scrollingCapture: "Scrolling Capture"
        case .captureText: "Capture Text"
        case .recordScreen: "Record Screen"
        case .recordGIF: "Record GIF"
        case .recordStudio: "Record in Studio Mode"
        case .toggleDesktopIcons: "Toggle Desktop Icons"
        case .openAnnotate: "Open Annotate Tool"
        case .openFromClipboard: "Open From Clipboard"
        case .annotateLast: "Annotate Last Screenshot"
        case .pinScreenshot: "Choose and Pin an Image"
        case .pinLast: "Pin Last Screenshot"
        case .togglePins: "Toggle Pins Visibility"
        case .closeAllOverlays: "Close All Overlays"
        case .openHistory: "Open Capture History"
        case .restoreLastCapture: "Restore Last Capture"
        case .colorPicker: "Pick Color"
        case .openPreferences: "Settings…"
        }
    }

    /// Shortcut-pane grouping.
    public var group: String {
        switch self {
        case .allInOne, .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer,
             .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .captureAreaAndUpload,
             .captureAreaAndPin, .scrollingCapture, .captureText, .colorPicker: "Screenshots"
        case .recordScreen, .recordGIF, .recordStudio: "Screen Recording"
        case .openAnnotate, .openFromClipboard, .annotateLast: "Annotate"
        case .pinScreenshot, .pinLast, .togglePins, .closeAllOverlays: "Overlays"
        case .toggleDesktopIcons, .openHistory, .restoreLastCapture, .openPreferences: "Other"
        }
    }

    /// Defaults avoid the macOS ⇧⌘3/4/5 system shortcuts; the user can switch to those in onboarding.
    public var defaultShortcut: Shortcut? {
        let optShift: NSEvent.ModifierFlags = [.option, .shift]
        switch self {
        case .captureFullscreen: return Shortcut(key: kVK_ANSI_3, modifiers: optShift)
        case .captureArea: return Shortcut(key: kVK_ANSI_4, modifiers: optShift)
        case .allInOne: return Shortcut(key: kVK_ANSI_5, modifiers: optShift)
        case .recordScreen: return Shortcut(key: kVK_ANSI_6, modifiers: optShift)
        case .captureText: return Shortcut(key: kVK_ANSI_2, modifiers: optShift)
        case .capturePreviousArea: return Shortcut(key: kVK_ANSI_7, modifiers: optShift)
        case .scrollingCapture: return Shortcut(key: kVK_ANSI_8, modifiers: optShift)
        case .openHistory: return Shortcut(key: kVK_ANSI_H, modifiers: optShift)
        default: return nil
        }
    }

    /// Opposite mapping used by the URL scheme (`shotcraft://capture-area`).
    public var urlCommand: String {
        rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
    }
}

/// A key + modifier combination.
public struct Shortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifierFlags: UInt  // NSEvent.ModifierFlags.rawValue, device-independent bits only

    public init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }
    public init(key: Int, modifiers: NSEvent.ModifierFlags) { self.init(keyCode: UInt32(key), modifiers: modifiers) }
    public init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    public var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    /// The menu-item key equivalent for this shortcut, when it maps to a printable character.
    public var keyEquivalent: String {
        let name = Shortcut.keyName(keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    /// Shortcuts macOS reserves for its own screenshot tool.
    public var isSystemScreenshotShortcut: Bool {
        let sc: NSEvent.ModifierFlags = [.command, .shift]
        let m = modifiers.subtracting(.control)
        return m == sc && [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6].contains(Int(keyCode))
    }

    public static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
            kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let s = special[Int(code)] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

public extension Defaults.Keys {
    /// User-assigned shortcuts. Missing entry = action default; explicit `nil` = cleared by user.
    static let shortcuts = Key<[String: Shortcut?]>("shortcuts", default: [:])
}

public extension AppAction {
    var shortcut: Shortcut? {
        get {
            let map = Defaults[.shortcuts]
            if let entry = map[rawValue] { return entry }
            return defaultShortcut
        }
        nonmutating set {
            var map = Defaults[.shortcuts]
            map[rawValue] = .some(newValue)
            Defaults[.shortcuts] = map
        }
    }
}
