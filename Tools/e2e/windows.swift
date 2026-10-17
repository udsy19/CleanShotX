// Lists Super Screenshot's on-screen windows as `id layer x y width height title` (CG coordinates, top-left origin).
// `windows screen` prints the main screen's height in points instead.
import AppKit
if CommandLine.arguments.dropFirst().first == "screen" {
    print(Int(NSScreen.screens.first?.frame.height ?? 0)); exit(0)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where ["Super Screenshot", "SuperScreenshot"].contains(w[kCGWindowOwnerName as String] as? String ?? "") {
    let b = w[kCGWindowBounds as String] as! [String: CGFloat]
    guard (b["Height"] ?? 0) > 40 else { continue }
    print(w[kCGWindowNumber as String]!, w[kCGWindowLayer as String]!, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!),
          w[kCGWindowName as String] as? String ?? "")
}
