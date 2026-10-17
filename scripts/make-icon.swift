// Renders the Shotcraft app icon (original artwork) into an .iconset directory.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 body with shadow margin.
    let inset = s * 0.098
    let body = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(srgbRed: 0.33, green: 0.36, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.62, green: 0.30, blue: 0.95, alpha: 1),
        CGColor(srgbRed: 0.98, green: 0.42, blue: 0.62, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft top highlight.
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
    ctx.fillEllipse(in: CGRect(x: body.minX - body.width * 0.2, y: body.midY, width: body.width * 1.4, height: body.height))
    ctx.restoreGState()

    // Viewfinder corners.
    let f = body.insetBy(dx: body.width * 0.2, dy: body.height * 0.2)
    let arm = f.width * 0.28, lw = s * 0.055
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (cx, cy, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: cx, y: cy + dy * arm)); ctx.addLine(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
    }
    ctx.strokePath()
    // Center sparkle (4-point star).
    let c = CGPoint(x: f.midX, y: f.midY), r = f.width * 0.2
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.move(to: CGPoint(x: c.x, y: c.y + r))
    ctx.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
    ctx.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
    ctx.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
    ctx.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
