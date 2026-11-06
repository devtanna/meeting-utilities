// Renders the macOS app icon from the brand logo (logo/logoipsum-225.svg): the mark centred on a white rounded tile.
// Run: swift scripts/make-icon.swift logo/logoipsum-225.svg App/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit
let logo = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
var images: [[String: String]] = []
for (pt, scale) in sizes {
    let px = pt * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px)
    // macOS icon grid: ~10% margin around the tile, continuous-corner radius ≈ 22.5% of the tile.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.94, alpha: 1))!.draw(in: path, angle: -90)
    NSColor(white: 0, alpha: 0.08).setStroke(); path.lineWidth = max(1, s / 256); path.stroke()
    // Small sizes get a slightly larger mark so it stays legible.
    let markScale: CGFloat = px <= 32 ? 0.66 : 0.56
    let side = tile.width * markScale
    logo.draw(in: NSRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side * logo.size.height / logo.size.width))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
try! json.write(to: out.appendingPathComponent("Contents.json"))
