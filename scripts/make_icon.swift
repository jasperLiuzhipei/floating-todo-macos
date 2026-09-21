import Cocoa
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 512)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 472, height: 472), xRadius: 106, yRadius: 106)
        NSGradient(starting: NSColor(red: 0.08, green: 0.25, blue: 0.36, alpha: 1),
                   ending: NSColor(red: 0.11, green: 0.47, blue: 0.50, alpha: 1))!.draw(in: tile, angle: 70)
        for (index, y) in [CGFloat(338), 248, 158].enumerated() {
            let box = NSBezierPath(roundedRect: NSRect(x: 105, y: y - 18, width: 42, height: 42), xRadius: 10, yRadius: 10)
            (index == 0 ? NSColor(red: 0.65, green: 0.95, blue: 0.74, alpha: 1) : NSColor.white.withAlphaComponent(0.22)).setFill()
            box.fill()
            NSColor.white.withAlphaComponent(index == 0 ? 0.72 : 0.96).setFill()
            NSBezierPath(roundedRect: NSRect(x: 179, y: y - 3, width: index == 2 ? 136 : 220, height: 14), xRadius: 7, yRadius: 7).fill()
        }
        NSColor(red: 0.07, green: 0.3, blue: 0.3, alpha: 1).setStroke()
        let check = NSBezierPath()
        check.lineWidth = 6
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: NSPoint(x: 113, y: 341))
        check.line(to: NSPoint(x: 123, y: 331))
        check.line(to: NSPoint(x: 140, y: 351))
        check.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = multiplier == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
