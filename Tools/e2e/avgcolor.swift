import AppKit
let img = NSImage(contentsOfFile: CommandLine.arguments[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .medium; ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
print(img.width, img.height, p[0], p[1], p[2])
