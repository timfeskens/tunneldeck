#!/usr/bin/env swift
import AppKit

// Original vector artwork, generated locally; no downloaded assets or fonts.
// Two parallel tunnels with a common direction, on a restrained macOS tile.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func image(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -13), blur: 28, color: NSColor.black.withAlphaComponent(0.23).cgColor)
    NSColor(calibratedRed: 0.07, green: 0.20, blue: 0.37, alpha: 1).setFill()
    tile.fill()
    cg.restoreGState()
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.68, alpha: 1),
                              ending: NSColor(calibratedRed: 0.06, green: 0.17, blue: 0.32, alpha: 1))!
    gradient.draw(in: tile, angle: -65)
    NSColor.white.withAlphaComponent(0.15).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    func tunnel(y: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 266, y: y))
        path.line(to: NSPoint(x: 457, y: y))
        path.curve(to: NSPoint(x: 590, y: y + 72), controlPoint1: NSPoint(x: 520, y: y), controlPoint2: NSPoint(x: 531, y: y + 72))
        path.line(to: NSPoint(x: 758, y: y + 72))
        path.lineWidth = 54
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 706, y: y + 126))
        arrow.line(to: NSPoint(x: 760, y: y + 72))
        arrow.line(to: NSPoint(x: 706, y: y + 18))
        arrow.lineWidth = 45
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 216, y: y - 40, width: 80, height: 80)).fill()
    }
    tunnel(y: 585, color: .white)
    tunnel(y: 335, color: NSColor(calibratedRed: 0.36, green: 0.91, blue: 0.83, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try image(size: points * scale).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try image(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated Resources/AppIcon.icns and AppIcon.png")
