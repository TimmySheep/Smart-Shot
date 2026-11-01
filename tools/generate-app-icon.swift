import AppKit

// Reproducible macOS 14+ asset-catalog artwork. No third-party dependencies.
// Coordinates are a 1024-unit canvas, with a transparent macOS icon margin.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "SmartShot/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func drawIcon(pixels: Int) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
        pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                            xRadius: 202, yRadius: 202)
    NSGradient(starting: color(0x123B52), ending: color(0x147D88))!
        .draw(in: tile, angle: 55)

    // A retained frame behind the current selection: local frame-buffer metaphor.
    color(0x8EE5DF, alpha: 0.26).setFill()
    NSBezierPath(roundedRect: NSRect(x: 338, y: 328, width: 388, height: 306),
                 xRadius: 44, yRadius: 44).fill()
    color(0xE6FFFA).setFill()
    NSBezierPath(roundedRect: NSRect(x: 298, y: 378, width: 388, height: 306),
                 xRadius: 44, yRadius: 44).fill()

    // Four substantial capture corners. No tiny details or lettering.
    color(0xFFFFFF).setStroke()
    let corners = NSBezierPath()
    corners.lineWidth = 38
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for points: [NSPoint] in [
        [NSPoint(x: 332, y: 758), NSPoint(x: 230, y: 758), NSPoint(x: 230, y: 656)],
        [NSPoint(x: 230, y: 412), NSPoint(x: 230, y: 292), NSPoint(x: 350, y: 292)],
        [NSPoint(x: 674, y: 292), NSPoint(x: 794, y: 292), NSPoint(x: 794, y: 412)]
    ] {
        corners.move(to: points[0])
        corners.line(to: points[1])
        corners.line(to: points[2])
    }
    corners.stroke()

    // The fourth corner becomes the "smart" capture signal.
    color(0xFFD37B).setFill()
    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: 770, y: 844))
    spark.curve(to: NSPoint(x: 874, y: 740),
                controlPoint1: NSPoint(x: 788, y: 762), controlPoint2: NSPoint(x: 792, y: 758))
    spark.curve(to: NSPoint(x: 770, y: 636),
                controlPoint1: NSPoint(x: 792, y: 722), controlPoint2: NSPoint(x: 788, y: 718))
    spark.curve(to: NSPoint(x: 666, y: 740),
                controlPoint1: NSPoint(x: 752, y: 718), controlPoint2: NSPoint(x: 748, y: 722))
    spark.curve(to: NSPoint(x: 770, y: 844),
                controlPoint1: NSPoint(x: 748, y: 758), controlPoint2: NSPoint(x: 752, y: 762))
    spark.close()
    spark.fill()

    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent("icon-\(pixels).png"))
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] { try drawIcon(pixels: pixels) }
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        images.append(["idiom": "mac", "size": "\(size)x\(size)",
                       "scale": "\(scale)x", "filename": "icon-\(size * scale).png"])
    }
}
let manifest: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Generated AppIcon (16–1024 px): \(output.path)")
