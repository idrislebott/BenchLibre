import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Output iconset directory required") }
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in 1...2 {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(red: 0.065, green: 0.083, blue: 0.102, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976), xRadius: 222, yRadius: 222).fill()
        NSColor(white: 1, alpha: 0.065).setStroke()
        let border = NSBezierPath(roundedRect: NSRect(x: 45, y: 45, width: 934, height: 934), xRadius: 203, yRadius: 203)
        border.lineWidth = 4; border.stroke()
        NSColor(red: 0.48, green: 0.94, blue: 0.73, alpha: 1).setStroke()
        let wave = NSBezierPath(); wave.lineWidth = 62; wave.lineCapStyle = .round; wave.lineJoinStyle = .round
        wave.move(to: NSPoint(x: 205, y: 473)); wave.line(to: NSPoint(x: 337, y: 473))
        wave.line(to: NSPoint(x: 423, y: 671)); wave.line(to: NSPoint(x: 540, y: 337))
        wave.line(to: NSPoint(x: 638, y: 552)); wave.line(to: NSPoint(x: 707, y: 473)); wave.line(to: NSPoint(x: 819, y: 473))
        wave.stroke()
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = representation.representation(using: .png, properties: [:])!
        let suffix = scale == 1 ? "" : "@2x"
        try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
