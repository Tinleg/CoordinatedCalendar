#!/usr/bin/env swift

// Renders Docs/images/social-preview.png (1280×640), the image GitHub shows when the repository is linked.
// Run from the repository root after scripts/generate-icon.swift, which provides the C² icon.

import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconURL = rootURL.appendingPathComponent("Packaging/CoordinatedCalendar.iconset/icon_512x512@2x.png")
let outputURL = rootURL.appendingPathComponent("Docs/images/social-preview.png")

guard let icon = NSImage(contentsOf: iconURL) else {
    fatalError("Run scripts/generate-icon.swift first; \(iconURL.path) is missing.")
}

let size = NSSize(width: 1280, height: 640)
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let bounds = NSRect(origin: .zero, size: size)
NSGradient(colors: [
    NSColor(calibratedRed: 0.03, green: 0.09, blue: 0.29, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.27, blue: 0.66, alpha: 1)
])?.draw(in: bounds, angle: 35)

// Faint rings echoing the C, behind everything.
NSColor(calibratedWhite: 1, alpha: 0.05).setStroke()
for (radius, width) in [(430.0, 70.0), (560.0, 40.0)] {
    let ring = NSBezierPath()
    ring.appendArc(withCenter: NSPoint(x: 250, y: 320), radius: radius, startAngle: 0, endAngle: 360)
    ring.lineWidth = width
    ring.stroke()
}

// The C² icon on the left, with a soft shadow.
let iconRect = NSRect(x: 80, y: 140, width: 360, height: 360)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
icon.draw(in: iconRect)
NSGraphicsContext.restoreGraphicsState()

func draw(_ text: String, font: NSFont, color: NSColor, at origin: NSPoint, width: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 4
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    let string = text as NSString
    let height = string.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin], attributes: attributes).height
    string.draw(with: NSRect(x: origin.x, y: origin.y - height, width: width, height: height), options: [.usesLineFragmentOrigin], attributes: attributes)
}

let textX: CGFloat = 500
let textWidth: CGFloat = 710
let amber = NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.24, alpha: 1)
draw("CoordinatedCalendar", font: .systemFont(ofSize: 66, weight: .bold), color: .white, at: NSPoint(x: textX, y: 440), width: textWidth)
draw("Coordinate free/busy time across all your calendar accounts on macOS.",
     font: .systemFont(ofSize: 32, weight: .medium), color: NSColor(calibratedWhite: 1, alpha: 0.92),
     at: NSPoint(x: textX, y: 350), width: textWidth)
draw("Consolidate every event in one calendar · sanitized busy blocks everywhere else",
     font: .systemFont(ofSize: 22, weight: .regular), color: NSColor(calibratedWhite: 1, alpha: 0.7),
     at: NSPoint(x: textX, y: 250), width: textWidth)
draw("Local  ·  EventKit  ·  No API connections",
     font: .systemFont(ofSize: 22, weight: .semibold), color: amber,
     at: NSPoint(x: textX, y: 170), width: textWidth)

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: outputURL)
print("Wrote \(outputURL.path)")
