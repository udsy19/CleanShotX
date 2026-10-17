// Renders the Super Screenshot app icon into an .iconset directory.
// Design: a warm paper squircle with ink viewfinder corners and a red "capture" dot — the same palette as the website.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 body, room for the drop shadow.
    let inset = s * 0.098
    let body = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.30))
    ctx.addPath(path); ctx.setFillColor(color(0xF5F3EE)); ctx.fillPath()
    ctx.restoreGState()

    // Paper with a barely-there top light, and a hairline edge.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let paper = CGGradient(colorsSpace: srgb, colors: [color(0xFBFAF7), color(0xEDEAE2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(color(0x16150F, 0.10)); ctx.setLineWidth(max(1, s * 0.004)); ctx.strokePath()

    // Ink viewfinder corners.
    let f = body.insetBy(dx: body.width * 0.19, dy: body.height * 0.19)
    let arm = f.width * 0.27, lw = s * 0.062
    ctx.setStrokeColor(color(0x16150F)); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (cx, cy, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
        ctx.move(to: CGPoint(x: cx, y: cy + dy * arm)); ctx.addLine(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
    }
    ctx.strokePath()

    // Red capture dot.
    let r = f.width * 0.16
    ctx.setFillColor(color(0xE5484D))
    ctx.fillEllipse(in: CGRect(x: f.midX - r, y: f.midY - r, width: r * 2, height: r * 2))

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
