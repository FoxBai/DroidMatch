#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-mac-icon.swift <output.png>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pixels = 1_024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("could not create icon bitmap")
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

let tileRect = NSRect(x: 58, y: 58, width: 908, height: 908)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 218, yRadius: 218)
let shadow = NSShadow()
shadow.shadowColor = color(0x04100d, alpha: 0.42)
shadow.shadowBlurRadius = 38
shadow.shadowOffset = NSSize(width: 0, height: -20)
shadow.set()
color(0x0b241e).setFill()
tile.fill()

NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(
    starting: color(0x16463b),
    ending: color(0x071713)
)?.draw(in: tileRect, angle: 135)

let glow = NSBezierPath(ovalIn: NSRect(x: 258, y: 258, width: 508, height: 508))
NSGradient(colors: [color(0x76e6c5, alpha: 0.18), .clear])?.draw(in: glow, angle: 90)
NSGraphicsContext.restoreGraphicsState()

let inset = NSBezierPath(roundedRect: tileRect.insetBy(dx: 9, dy: 9), xRadius: 210, yRadius: 210)
inset.lineWidth = 3
color(0xffffff, alpha: 0.13).setStroke()
inset.stroke()

func drawEndpoint(_ path: NSBezierPath, color strokeColor: NSColor) {
    path.lineWidth = 72
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    strokeColor.setStroke()
    path.stroke()
}

let left = NSBezierPath()
left.move(to: NSPoint(x: 454, y: 718))
left.line(to: NSPoint(x: 402, y: 718))
left.curve(
    to: NSPoint(x: 236, y: 552),
    controlPoint1: NSPoint(x: 306, y: 718),
    controlPoint2: NSPoint(x: 236, y: 648)
)
left.line(to: NSPoint(x: 236, y: 472))
left.curve(
    to: NSPoint(x: 402, y: 306),
    controlPoint1: NSPoint(x: 236, y: 376),
    controlPoint2: NSPoint(x: 306, y: 306)
)
left.line(to: NSPoint(x: 454, y: 306))
drawEndpoint(left, color: color(0x76e6c5))

let right = NSBezierPath()
right.move(to: NSPoint(x: 570, y: 718))
right.line(to: NSPoint(x: 622, y: 718))
right.curve(
    to: NSPoint(x: 788, y: 552),
    controlPoint1: NSPoint(x: 718, y: 718),
    controlPoint2: NSPoint(x: 788, y: 648)
)
right.line(to: NSPoint(x: 788, y: 472))
right.curve(
    to: NSPoint(x: 622, y: 306),
    controlPoint1: NSPoint(x: 788, y: 376),
    controlPoint2: NSPoint(x: 718, y: 306)
)
right.line(to: NSPoint(x: 570, y: 306))
drawEndpoint(right, color: color(0xf3f7f2))

let match = NSBezierPath()
match.move(to: NSPoint(x: 512, y: 618))
match.curve(to: NSPoint(x: 618, y: 512), controlPoint1: NSPoint(x: 536, y: 618), controlPoint2: NSPoint(x: 618, y: 536))
match.curve(to: NSPoint(x: 512, y: 406), controlPoint1: NSPoint(x: 618, y: 488), controlPoint2: NSPoint(x: 536, y: 406))
match.curve(to: NSPoint(x: 406, y: 512), controlPoint1: NSPoint(x: 488, y: 406), controlPoint2: NSPoint(x: 406, y: 488))
match.curve(to: NSPoint(x: 512, y: 618), controlPoint1: NSPoint(x: 406, y: 536), controlPoint2: NSPoint(x: 488, y: 618))
match.close()

let matchShadow = NSShadow()
matchShadow.shadowColor = color(0x000000, alpha: 0.25)
matchShadow.shadowBlurRadius = 20
matchShadow.shadowOffset = NSSize(width: 0, height: -10)
matchShadow.set()
color(0xffb66e).setFill()
match.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not encode icon PNG")
}
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
