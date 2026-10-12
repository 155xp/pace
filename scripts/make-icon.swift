// Draws the app icon: three usage bars crossed by the pace line.
// swift scripts/make-icon.swift Pace/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824pt body, inset 100, corner radius ~185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [NSColor(white: 0.2, alpha: 1).cgColor, NSColor(white: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    let left = 236.0, width = 552.0, height = 64.0
    let fills = [0.78, 0.46, 0.3]
    for (i, fill) in fills.enumerated() {
        let y = 356 + Double(i) * 128
        let track = CGRect(x: left, y: y, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: 32, cornerHeight: 32, transform: nil))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.12).cgColor); ctx.fillPath()
        let bar = CGRect(x: left, y: y, width: width * fill, height: height)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 32, cornerHeight: 32, transform: nil))
        ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor); ctx.fillPath()
    }
    let tickX = left + width * 0.6
    let tick = CGRect(x: tickX - 9, y: 300, width: 18, height: 432)
    ctx.addPath(CGPath(roundedRect: tick, cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.setFillColor(NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor); ctx.fillPath()
    return true
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
