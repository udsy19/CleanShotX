import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global hotkeys via Carbon `RegisterEventHotKey` (works without Accessibility permission).
@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    private struct Registration { let ref: EventHotKeyRef; let handler: () -> Void }
    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    /// While a shortcut recorder is focused, hotkeys are suspended so they can be re-recorded.
    public var isSuspended = false

    private init() {}

    /// Registers a hotkey and returns a token for `unregister`. Returns nil if the combo is taken.
    @discardableResult
    public func register(_ shortcut: Shortcut, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_4354) /* 'SHCT' */, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        registrations[id] = Registration(ref: ref, handler: handler)
        return id
    }

    public func unregister(_ token: UInt32) {
        if let r = registrations.removeValue(forKey: token) { UnregisterEventHotKey(r.ref) }
    }

    public func unregisterAll() {
        for (_, r) in registrations { UnregisterEventHotKey(r.ref) }
        registrations.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        guard !isSuspended, let r = registrations[id] else { return }
        r.handler()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Recorder control

/// Click-to-record shortcut field. Esc cancels, ⌫ clears.
public final class ShortcutRecorderView: NSView {
    public var shortcut: Shortcut? { didSet { needsDisplay = true } }
    public var onChange: ((Shortcut?) -> Void)?
    /// Return a reason string to reject a shortcut (e.g. already used).
    public var validator: ((Shortcut) -> String?)?

    private var recording = false { didSet { needsDisplay = true; HotkeyCenter.shared.isSuspended = recording } }
    private var monitor: Any?

    public override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    public override var acceptsFirstResponder: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        if recording { stop(); return }
        // Clear button region (right 20pt) when a shortcut exists.
        let p = convert(event.locationInWindow, from: nil)
        if shortcut != nil, p.x > bounds.maxX - 22 { set(nil); return }
        window?.makeFirstResponder(self)
        start()
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, self.recording else { return e }
            if e.type == .flagsChanged { self.needsDisplay = true; return nil }
            if e.keyCode == UInt16(kVK_Escape) && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self.stop(); return nil
            }
            if e.keyCode == UInt16(kVK_Delete) && e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                self.set(nil); self.stop(); return nil
            }
            guard let s = Shortcut(event: e) else { return nil }
            let fnKey = (UInt32(kVK_F1)...UInt32(kVK_F20)).contains(s.keyCode)
            if s.modifiers.intersection([.command, .option, .control]).isEmpty && !fnKey {
                NSSound.beep(); return nil  // require a real modifier
            }
            if let reason = self.validator?(s) {
                let alert = NSAlert(); alert.messageText = reason; alert.runModal()
                return nil
            }
            self.set(s); self.stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func set(_ s: Shortcut?) { shortcut = s; onChange?(s) }

    public override func resignFirstResponder() -> Bool { stop(); return true }

    public override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let text: String
        let color: NSColor
        if recording {
            let mods = Shortcut(keyCode: 0, modifiers: NSEvent.modifierFlags).displayString.dropLast()
            text = mods.isEmpty ? "Type shortcut…" : String(mods)
            color = .secondaryLabelColor
        } else if let shortcut {
            text = shortcut.displayString; color = .labelColor
        } else {
            text = "Record Shortcut"; color = .tertiaryLabelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)

        if shortcut != nil && !recording {
            let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
            x?.draw(in: NSRect(x: bounds.maxX - 19, y: (bounds.height - 13) / 2, width: 13, height: 13))
        }
    }
}

/// SwiftUI wrapper bound to an `AppAction`'s stored shortcut.
public struct ShortcutRecorder: NSViewRepresentable {
    let action: AppAction
    public init(for action: AppAction) { self.action = action }

    public func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        v.shortcut = action.shortcut
        v.validator = { s in
            if let other = AppAction.allCases.first(where: { $0 != action && $0.shortcut == s }) {
                return "Shortcut is used for another action (\(other.title))."
            }
            return nil
        }
        v.onChange = { action.shortcut = $0 }
        return v
    }

    public func updateNSView(_ v: ShortcutRecorderView, context: Context) { v.shortcut = action.shortcut }
}
