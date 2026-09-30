import AppKit
import Foundation

// Action extensions use a monochrome, transparent template, matching the stacked-photo motif.
guard CommandLine.arguments.count == 2 else {
  fatalError("usage: swift Tools/CreateActionIcon.swift output.png")
}
let size = 1024
guard
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
  let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("Unable to create template context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
NSColor.white.setStroke()
func photoFrame(_ rect: NSRect, angle: CGFloat) {
  NSGraphicsContext.saveGraphicsState()
  context.cgContext.translateBy(x: rect.midX, y: rect.midY)
  context.cgContext.rotate(by: angle * .pi / 180)
  let local = NSRect(
    x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
  let path = NSBezierPath(roundedRect: local, xRadius: 70, yRadius: 70)
  path.lineWidth = 50
  path.stroke()
  NSGraphicsContext.restoreGraphicsState()
}
photoFrame(NSRect(x: 200, y: 300, width: 490, height: 490), angle: 12)
// Knock out the rear frame beneath the foreground frame to keep the small-size silhouette clear.
context.cgContext.saveGState()
context.cgContext.translateBy(x: 610, y: 465)
context.cgContext.rotate(by: -10 * .pi / 180)
let foreground = NSBezierPath(
  roundedRect: NSRect(x: -265, y: -265, width: 530, height: 530), xRadius: 90, yRadius: 90)
context.cgContext.setBlendMode(.clear)
foreground.fill()
context.cgContext.restoreGState()
photoFrame(NSRect(x: 365, y: 220, width: 490, height: 490), angle: -10)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
  fatalError("Unable to encode template")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
