import AppKit
let pb = NSPasteboard.general
print("types:", (pb.types ?? []).map(\.rawValue).joined(separator: ","))
if let s = pb.string(forType: .string) { print("string:", s.prefix(200)) }
if let d = pb.data(forType: .png), let r = NSBitmapImageRep(data: d) { print("png:", r.pixelsWide, r.pixelsHigh) }
