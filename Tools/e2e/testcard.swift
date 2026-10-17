import AppKit
// Synthetic test card: colored quadrants, grid, and OCR-able text.
let w = 1200, h = 800
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.95, 0.3, 0.3), (0.3, 0.75, 0.4), (0.3, 0.5, 0.95), (0.98, 0.8, 0.25)]
for (i, c) in colors.enumerated() {
    ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
    ctx.fill(CGRect(x: (i % 2) * w / 2, y: (i / 2) * h / 2, width: w / 2, height: h / 2))
}
ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 150, y: 250, width: 900, height: 300))
let ns = NSGraphicsContext(cgContext: ctx, flipped: false); NSGraphicsContext.current = ns
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black]
("Shotcraft E2E 4721" as NSString).draw(at: NSPoint(x: 200, y: 420), withAttributes: attrs)
("The quick brown fox" as NSString).draw(at: NSPoint(x: 200, y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.darkGray])
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
