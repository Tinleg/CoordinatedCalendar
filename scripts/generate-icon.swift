#!/usr/bin/env swift

import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let packagingURL = rootURL.appendingPathComponent("Packaging", isDirectory: true)
let iconsetURL = packagingURL.appendingPathComponent("CoordinatedCalendar.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let icons: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for icon in icons {
    let image = NSImage(size: NSSize(width: icon.pixels, height: icon.pixels))
    image.lockFocus()

    let bounds = NSRect(x: 0, y: 0, width: icon.pixels, height: icon.pixels)
    NSColor.clear.setFill()
    bounds.fill()

    let inset = icon.pixels * 0.06
    let tileRect = bounds.insetBy(dx: inset, dy: inset)
    let radius = icon.pixels * 0.19
    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.11, green: 0.33, blue: 0.78, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.14, blue: 0.43, alpha: 1)
    ])
    gradient?.draw(in: tilePath, angle: 90)

    NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
    tilePath.lineWidth = max(1, icon.pixels * 0.012)
    tilePath.stroke()

    // A stylized "C²": a thick, round-capped arc for the C, with a rounded superscript 2 in an accent color
    // sitting in the C's upper-right opening.
    let size = icon.pixels
    let center = NSPoint(x: tileRect.midX - size * 0.045, y: tileRect.midY - size * 0.01)
    let arcRadius = size * 0.235
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: arcRadius, startAngle: 42, endAngle: 318, clockwise: false)
    arc.lineWidth = size * 0.115
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    let baseFont = NSFont.systemFont(ofSize: size * 0.25, weight: .heavy)
    let roundedFont = baseFont.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: size * 0.25) } ?? baseFont
    let superscript = "2" as NSString
    let superscriptAttributes: [NSAttributedString.Key: Any] = [
        .font: roundedFont,
        .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.24, alpha: 1)
    ]
    let superscriptSize = superscript.size(withAttributes: superscriptAttributes)
    superscript.draw(
        at: NSPoint(
            x: center.x + arcRadius * 0.95,
            y: center.y + arcRadius * 0.66 - superscriptSize.height * 0.22
        ),
        withAttributes: superscriptAttributes
    )

    image.unlockFocus()

    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(
            domain: "CoordinatedCalendarIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not render \(icon.name)."]
        )
    }

    try pngData.write(to: iconsetURL.appendingPathComponent(icon.name))
}

// Build the .icns next to the iconset.
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", packagingURL.appendingPathComponent("CoordinatedCalendar.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "CoordinatedCalendarIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed."])
}
print("Wrote Packaging/CoordinatedCalendar.icns")
