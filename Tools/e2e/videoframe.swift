import AVFoundation
import AppKit
let a = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let g = AVAssetImageGenerator(asset: a); g.appliesPreferredTrackTransform = true
let t = CMTime(seconds: Double(CommandLine.arguments[3])!, preferredTimescale: 600)
let img = try! g.copyCGImage(at: t, actualTime: nil)
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("duration", CMTimeGetSeconds(a.duration), "frame", img.width, img.height)
