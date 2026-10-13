// Regenerate the native vector artwork: swift scripts/MakeIcon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Still.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
}
func artwork(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scaleX(by: CGFloat(size) / 1024, yBy: CGFloat(size) / 1024)
    transform.concat()
    let shell = NSBezierPath(roundedRect: NSRect(x: 82, y: 88, width: 860, height: 860), xRadius: 188, yRadius: 188)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 22
    shadow.shadowColor = color(0.03, 0.17, 0.14, 0.22)
    shadow.set()
    color(0.86, 0.92, 0.88).setFill(); shell.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.76, 0.84, 0.79), ending: color(0.98, 0.995, 0.97))!.draw(in: shell, angle: 90)
    color(1, 1, 1, 0.72).setStroke(); shell.lineWidth = 4; shell.stroke()
    let tiles: [(NSRect, NSColor, NSColor)] = [
        (NSRect(x: 226, y: 312, width: 286, height: 478), color(0.065, 0.30, 0.27), color(0.18, 0.58, 0.49)),
        (NSRect(x: 538, y: 526, width: 260, height: 264), color(0.13, 0.43, 0.37), color(0.38, 0.72, 0.58)),
        (NSRect(x: 538, y: 312, width: 260, height: 188), color(0.34, 0.62, 0.49), color(0.70, 0.86, 0.69))]
    for (rect, bottom, top) in tiles {
        let path = NSBezierPath(roundedRect: rect, xRadius: 38, yRadius: 38)
        NSGraphicsContext.saveGraphicsState()
        let tileShadow = NSShadow()
        tileShadow.shadowOffset = NSSize(width: 0, height: -8)
        tileShadow.shadowBlurRadius = 15
        tileShadow.shadowColor = color(0.04, 0.20, 0.16, 0.20)
        tileShadow.set(); bottom.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: bottom, ending: top)!.draw(in: path, angle: 90)
        top.blended(withFraction: 0.3, of: .white)!.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 3; path.stroke()
    }
    let slot = NSBezierPath(roundedRect: NSRect(x: 296, y: 214, width: 360, height: 15), xRadius: 7.5, yRadius: 7.5)
    color(0.44, 0.57, 0.49, 0.30).setFill(); slot.fill()
    let led = NSBezierPath(ovalIn: NSRect(x: 703, y: 207, width: 27, height: 27))
    color(0.18, 0.52, 0.39).setFill(); led.fill()
    color(0.60, 0.90, 0.68).setFill()
    NSBezierPath(ovalIn: NSRect(x: 709, y: 215, width: 13, height: 13)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try artwork(size: size * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try artwork(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Still/Resources/StillIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Still/Resources/StillIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
