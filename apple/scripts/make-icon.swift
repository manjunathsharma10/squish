// Renders the app icon: an orange ball squished between two black plates.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Squish.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Tile, on Apple's 824pt icon grid with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.985, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.93, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()

    // Plates and the squished ball.
    let ink = CGColor(gray: 0.04, alpha: 1)
    let ballW: CGFloat = 470, ballH: CGFloat = 250, plate: CGFloat = 30, gap: CGFloat = 14
    let center = CGPoint(x: 512, y: 512)
    ctx.setFillColor(ink)
    ctx.fill(CGRect(x: center.x - 250, y: center.y + ballH / 2 + gap, width: 500, height: plate))
    ctx.fill(CGRect(x: center.x - 250, y: center.y - ballH / 2 - gap - plate, width: 500, height: plate))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.30, blue: 0, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - ballW / 2, y: center.y - ballH / 2, width: ballW, height: ballH))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: out.appendingPathComponent(name))
    }
}
