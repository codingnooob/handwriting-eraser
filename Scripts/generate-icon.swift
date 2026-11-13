import AppKit
import Foundation

// Rebuild Packaging/AppIcon.icns from this 1024px source with iconutil.
let output = CommandLine.arguments.dropFirst().first ?? "/tmp/HandwritingEraser-icon.png"
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.80, alpha: 1),
           ending: NSColor(calibratedRed: 0.20, green: 0.27, blue: 0.69, alpha: 1))!
    .draw(in: background, angle: 70)

let paper = NSBezierPath(roundedRect: NSRect(x: 260, y: 215, width: 480, height: 605), xRadius: 48, yRadius: 48)
NSColor.white.setFill()
paper.fill()
NSColor(calibratedRed: 0.78, green: 0.84, blue: 0.91, alpha: 1).setStroke()
for y in [695, 590, 485, 380] {
    let line = NSBezierPath()
    line.lineWidth = 18
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: 325, y: y))
    line.line(to: NSPoint(x: 645, y: y))
    line.stroke()
}

// A diagonal eraser overlays the handwritten strokes.
let eraser = NSBezierPath()
eraser.move(to: NSPoint(x: 500, y: 310))
eraser.line(to: NSPoint(x: 660, y: 470))
eraser.line(to: NSPoint(x: 765, y: 365))
eraser.line(to: NSPoint(x: 605, y: 205))
eraser.close()
NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.86, alpha: 1).setFill()
eraser.fill()
NSColor(calibratedRed: 0.13, green: 0.35, blue: 0.53, alpha: 1).setStroke()
eraser.lineWidth = 14
eraser.lineJoinStyle = .round
eraser.stroke()
let tip = NSBezierPath()
tip.move(to: NSPoint(x: 500, y: 310))
tip.line(to: NSPoint(x: 550, y: 360))
tip.line(to: NSPoint(x: 655, y: 255))
tip.line(to: NSPoint(x: 605, y: 205))
tip.close()
NSColor(calibratedRed: 0.96, green: 0.60, blue: 0.67, alpha: 1).setFill()
tip.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
