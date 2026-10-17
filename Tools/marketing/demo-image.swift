// Renders a fictional "dashboard" used to stage marketing screenshots (no real data).
// Usage: swift demo-image.swift out.png
import AppKit

let W = 1600, H = 1000
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)   // top-left origin for layout

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func rect(_ r: CGRect, _ c: NSColor, radius: CGFloat = 0) { c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() }
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = rgb(0x111827)) {
    (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

rect(CGRect(x: 0, y: 0, width: W, height: H), rgb(0xF5F6FA))
// Sidebar
rect(CGRect(x: 0, y: 0, width: 260, height: H), rgb(0xFFFFFF))
rect(CGRect(x: 28, y: 32, width: 36, height: 36), rgb(0x0F8B72), radius: 10)
text("Northwind", 76, 38, size: 20, weight: .bold)
for (i, item) in ["Overview", "Revenue", "Customers", "Campaigns", "Reports", "Settings"].enumerated() {
    let y = 120 + CGFloat(i) * 52
    if i == 0 { rect(CGRect(x: 16, y: y - 10, width: 228, height: 42), rgb(0xE3F4EF), radius: 10) }
    rect(CGRect(x: 32, y: y, width: 20, height: 20), i == 0 ? rgb(0x0F8B72) : rgb(0xC7CBD6), radius: 5)
    text(item, 66, y, size: 17, weight: i == 0 ? .semibold : .regular, color: i == 0 ? rgb(0x0B6B58) : rgb(0x4B5563))
}
// Header
text("Overview", 310, 40, size: 34, weight: .bold)
text("Q3 performance across all regions", 310, 88, size: 17, color: rgb(0x6B7280))
rect(CGRect(x: 1330, y: 44, width: 220, height: 44), rgb(0x0F8B72), radius: 12)
text("Export report", 1378, 55, size: 17, weight: .semibold, color: .white)
// KPI cards
let kpis = [("Revenue", "$482,190", "+12.4%", 0x10B981), ("Active users", "38,204", "+8.1%", 0x10B981),
            ("Churn", "2.3%", "−0.6%", 0x10B981), ("NPS", "64", "+5", 0x10B981)]
for (i, k) in kpis.enumerated() {
    let x = 310 + CGFloat(i) * 315
    rect(CGRect(x: x, y: 140, width: 295, height: 140), .white, radius: 18)
    text(k.0, x + 24, 164, size: 16, color: rgb(0x6B7280))
    text(k.1, x + 24, 196, size: 34, weight: .bold)
    text(k.2, x + 24, 246, size: 15, weight: .semibold, color: rgb(UInt32(k.3)))
}
// Chart card
rect(CGRect(x: 310, y: 310, width: 820, height: 640), .white, radius: 18)
text("Monthly revenue", 340, 336, size: 20, weight: .semibold)
let values: [CGFloat] = [0.42, 0.55, 0.48, 0.63, 0.58, 0.71, 0.66, 0.79, 0.74, 0.86, 0.81, 0.93]
for (i, v) in values.enumerated() {
    let x = 350 + CGFloat(i) * 64, h = 460 * v
    let grad = NSGradient(starting: rgb(0x34B394), ending: rgb(0x0F8B72))!
    let r = CGRect(x: x, y: 900 - h, width: 40, height: h)
    grad.draw(in: NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8), angle: 90)
    text(["J","F","M","A","M","J","J","A","S","O","N","D"][i], x + 14, 912, size: 14, color: rgb(0x9CA3AF))
}
// List card
rect(CGRect(x: 1160, y: 310, width: 390, height: 640), .white, radius: 18)
text("Top customers", 1188, 336, size: 20, weight: .semibold)
let people = [("Acme Corp", "$48,200", 0xF59E0B), ("Globex", "$41,950", 0x3B82F6), ("Initech", "$37,410", 0xEF4444),
              ("Umbrella", "$31,880", 0x10B981), ("Hooli", "$29,300", 0x0EA5E9), ("Stark Ind.", "$26,740", 0xF97316)]
for (i, p) in people.enumerated() {
    let y = 392 + CGFloat(i) * 88
    rect(CGRect(x: 1188, y: y, width: 44, height: 44), rgb(UInt32(p.2), 0.18), radius: 22)
    text(String(p.0.prefix(1)), 1203, y + 10, size: 19, weight: .bold, color: rgb(UInt32(p.2)))
    text(p.0, 1248, y + 4, size: 17, weight: .semibold)
    text("Enterprise plan", 1248, y + 26, size: 14, color: rgb(0x9CA3AF))
    text(p.1, 1440, y + 12, size: 17, weight: .semibold)
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
