// Tekent het app-icoon en schrijft een .iconset met alle formaten.
// Gebruik: swift make_icon.swift <uitvoermap.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // Achtergrond: afgeronde tegel (macOS-raster: 824 px tegel met 100 px marge).
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.93, green: 0.55, blue: 0.40, alpha: 1).cgColor,
        NSColor(srgbRed: 0.72, green: 0.33, blue: 0.22, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Meter: lichte achtergrondring + gevulde boog (~70%) met afgeronde uiteinden.
    let center = CGPoint(x: 512 * s, y: 470 * s)
    let radius = 270 * s
    let lw = 74 * s
    let start = CGFloat.pi * 1.25   // linksonder
    let sweep = CGFloat.pi * 1.5    // 270° meterbereik
    ctx.setLineCap(.round)
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
    ctx.strokePath()
    ctx.setStrokeColor(NSColor(srgbRed: 1, green: 0.97, blue: 0.93, alpha: 1).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep * 0.7, clockwise: true)
    ctx.strokePath()

    // Vonk in het midden: vierpuntige ster.
    let spark = CGMutablePath()
    let r1 = 130 * s, r2 = 34 * s
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 2
        let r = i % 2 == 0 ? r1 : r2
        let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
        i == 0 ? spark.move(to: p) : spark.addLine(to: p)
    }
    spark.closeSubpath()
    ctx.addPath(spark)
    ctx.setFillColor(NSColor(srgbRed: 1, green: 0.97, blue: 0.93, alpha: 1).cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: px).write(to: out.appendingPathComponent(name))
    }
}
print("Iconset geschreven: \(out.path)")
