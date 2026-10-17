// Renders the soft warm-stone wallpaper used as a backdrop for marketing screenshots.
// Usage: swift wallpaper.swift out.png <pixelWidth> <pixelHeight>   (written at 144 dpi)
import AppKit
let a = CommandLine.arguments, w = Int(a[2])!, h = Int(a[3])!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let base = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.80, green: 0.77, blue: 0.70, alpha: 1),
                                                 CGColor(srgbRed: 0.89, green: 0.87, blue: 0.82, alpha: 1),
                                                 CGColor(srgbRed: 0.93, green: 0.91, blue: 0.87, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
for (x, y, r, c) in [(0.2, 0.8, 0.55, (0.98, 0.96, 0.92)), (0.85, 0.2, 0.5, (0.74, 0.70, 0.62)), (0.6, 0.55, 0.4, (0.95, 0.93, 0.88))] {
    let g = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 0.55), CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 0)] as CFArray, locations: [0, 1])!
    let center = CGPoint(x: Double(w) * x, y: Double(h) * y)
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: Double(w) * r, options: [])
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
rep.size = NSSize(width: w / 2, height: h / 2)   // 144 dpi → point size = half the pixels
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
