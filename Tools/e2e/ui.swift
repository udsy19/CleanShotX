// UI driver for Shotcraft end-to-end tests (requires Accessibility permission for the calling terminal).
//   ui tree [maxDepth]          dump the AX tree of Shotcraft windows (role, labels, value, frame)
//   ui windows                  list Shotcraft AX windows
//   ui press "<label>"          AXPress the first element whose title/description/identifier matches
//   ui set "<label>" <value>    set AXValue
//   ui closewin ["<title>"]     press the close button of a window (all windows when no title)
//   ui raise "<title>"          raise a window
//   ui click|dclick x y         left click / double click at a global CG point (top-left origin)
//   ui move x y                 move the pointer
//   ui down x y / dragto x y / up x y    low-level drag steps
//   ui drag x1 y1 x2 y2         press, drag in 20 steps, release
//   ui scroll x y dy [steps]    pixel wheel events at a point
//   ui key <keycode> [cmd,shift,opt,ctrl]   key press (sent to the frontmost app!)
//   ui type "text"              type unicode text (sent to the frontmost app!)
import AppKit
import ApplicationServices

func app() -> AXUIElement {
    guard let r = NSRunningApplication.runningApplications(withBundleIdentifier: "com.udsy.shotcraft").first else { print("not running"); exit(2) }
    return AXUIElementCreateApplication(r.processIdentifier)
}
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func label(_ e: AXUIElement) -> String {
    [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXIdentifierAttribute), str(e, kAXHelpAttribute)].filter { !$0.isEmpty }.joined(separator: " | ")
}
func walk(_ e: AXUIElement, _ d: Int, _ max: Int, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(e, d) { return true }
    guard d < max else { return false }
    for c in children(e) { if walk(c, d + 1, max, visit) { return true } }
    return false
}
func windows() -> [AXUIElement] { children(app()).filter { str($0, kAXRoleAttribute) == "AXWindow" } }
func find(_ t: String) -> AXUIElement? {
    var hit: AXUIElement?
    for w in windows() { if walk(w, 0, 40, { e, _ in
        let l = label(e); let v = (attr(e, kAXValueAttribute) as? String) ?? ""
        if l.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(t) || v == t { hit = e; return true }
        return false }) { break } }
    return hit
}
func post(_ type: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }

let a = Array(CommandLine.arguments.dropFirst())
switch a.first {
case "tree":
    let max = a.count > 1 ? Int(a[1])! : 12
    for w in windows() { _ = walk(w, 0, max) { e, d in
        let v = attr(e, kAXValueAttribute).map { "\($0)" }.map { " =\($0.prefix(40))" } ?? ""
        let f = frame(e)
        print(String(repeating: "  ", count: d) + str(e, kAXRoleAttribute) + " [" + label(e) + "]" + v + " @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
        return false } }
case "press":
    guard let e = find(a[1]) else { print("not found: \(a[1])"); exit(1) }
    let r = AXUIElementPerformAction(e, kAXPressAction as CFString); print("press", a[1], r == .success ? "ok" : "err \(r.rawValue)")
case "set":
    guard let e = find(a[1]) else { print("not found"); exit(1) }
    let v: CFTypeRef = Double(a[2]).map { $0 as NSNumber } ?? (a[2] as NSString)
    print(AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, v).rawValue)
case "click":
    let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
    post(.mouseMoved, p); usleep(50_000); post(.leftMouseDown, p); usleep(60_000); post(.leftMouseUp, p)
case "dclick":
    let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
    for i in 1...2 { let d = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!; d.setIntegerValueField(.mouseEventClickState, value: Int64(i)); d.post(tap: .cghidEventTap)
        let u = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!; u.setIntegerValueField(.mouseEventClickState, value: Int64(i)); u.post(tap: .cghidEventTap); usleep(80_000) }
case "down":
    let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!); post(.mouseMoved, p); usleep(50_000); post(.leftMouseDown, p)
case "dragto":
    post(.leftMouseDragged, CGPoint(x: Double(a[1])!, y: Double(a[2])!))
case "up":
    post(.leftMouseUp, CGPoint(x: Double(a[1])!, y: Double(a[2])!))
case "scroll":
    // scroll x y dy [steps]: line-unit wheel events at a point (negative dy scrolls content down)
    let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!); post(.mouseMoved, p); usleep(30_000)
    let steps = a.count > 4 ? Int(a[4])! : 1
    for _ in 0..<steps { CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(a[3])!, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap); usleep(40_000) }
case "move":
    post(.mouseMoved, CGPoint(x: Double(a[1])!, y: Double(a[2])!))
case "drag":
    let p1 = CGPoint(x: Double(a[1])!, y: Double(a[2])!), p2 = CGPoint(x: Double(a[3])!, y: Double(a[4])!)
    post(.mouseMoved, p1); usleep(80_000); post(.leftMouseDown, p1); usleep(80_000)
    for i in 1...20 { let t = Double(i) / 20; post(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)); usleep(15_000) }
    usleep(80_000); post(.leftMouseUp, p2)
case "key":
    var flags: CGEventFlags = []
    if a.count > 2 { for m in a[2].split(separator: ",") { switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "opt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: break } } }
    let k = CGKeyCode(Int(a[1])!)
    let d = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: true)!; d.flags = flags; d.post(tap: .cghidEventTap)
    usleep(30_000)
    let u = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: false)!; u.flags = flags; u.post(tap: .cghidEventTap)
case "type":
    for ch in a[1].utf16 { let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!; var c = ch; d.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); d.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!; u.post(tap: .cghidEventTap); usleep(20_000) }
case "closewin":
    for w in windows() where a.count < 2 || str(w, kAXTitleAttribute) == a[1] {
        if let b = attr(w, kAXCloseButtonAttribute) { print("close", str(w, kAXTitleAttribute), AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString).rawValue) }
    }
case "raise":
    for w in windows() where str(w, kAXTitleAttribute) == a[1] { print(AXUIElementPerformAction(w, kAXRaiseAction as CFString).rawValue) }
case "windows":
    for w in windows() { let f = frame(w); print(str(w, kAXTitleAttribute), str(w, kAXSubroleAttribute), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)) }
default: print("usage: tree|press|set|click|dclick|move|drag|key|type")
}
