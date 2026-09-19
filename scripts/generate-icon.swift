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

    // "Calendar squared": a small idealized monthly desk-calendar page (header strip, binding rings, day grid
    // with a few busy days) and a rounded superscript 2 in the accent color at its upper right.
    let size = icon.pixels
    let navy = NSColor(calibratedRed: 0.05, green: 0.14, blue: 0.43, alpha: 1)
    let headerBlue = NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.95, alpha: 1)
    let amber = NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.24, alpha: 1)

    let page = NSRect(x: tileRect.midX - size * 0.31, y: tileRect.midY - size * 0.30, width: size * 0.52, height: size * 0.50)
    let pageRadius = size * 0.07
    NSGraphicsContext.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.30)
    pageShadow.shadowBlurRadius = size * 0.03
    pageShadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    pageShadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: page, xRadius: pageRadius, yRadius: pageRadius).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Header strip across the top of the page, clipped to the page's rounded corners.
    let headerHeight = page.height * 0.26
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: page, xRadius: pageRadius, yRadius: pageRadius).addClip()
    headerBlue.setFill()
    NSRect(x: page.minX, y: page.maxY - headerHeight, width: page.width, height: headerHeight).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Two binding rings straddling the top edge.
    let ringWidth = size * 0.045
    let ringHeight = size * 0.10
    for fraction in [0.28, 0.72] {
        let ring = NSRect(x: page.minX + page.width * fraction - ringWidth / 2, y: page.maxY - ringHeight * 0.55, width: ringWidth, height: ringHeight)
        navy.setFill()
        NSBezierPath(roundedRect: ring, xRadius: ringWidth / 2, yRadius: ringWidth / 2).fill()
    }

    // Day grid: 7 columns, with a few busy days. Small sizes get a coarser grid that stays legible.
    let columns = size >= 64 ? 7 : 3
    let rows = size >= 64 ? 5 : 2
    let busy: Set<Int> = size >= 64 ? [3, 9, 10, 18, 26, 31] : [1, 3]
    let body = NSRect(x: page.minX, y: page.minY, width: page.width, height: page.height - headerHeight)
        .insetBy(dx: page.width * 0.09, dy: page.height * 0.08)
    let gap = body.width * (size >= 64 ? 0.035 : 0.09)
    let cellWidth = (body.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
    let cellHeight = (body.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
    for row in 0..<rows {
        for column in 0..<columns {
            let index = row * columns + column
            let cell = NSRect(
                x: body.minX + CGFloat(column) * (cellWidth + gap),
                y: body.maxY - CGFloat(row + 1) * cellHeight - CGFloat(row) * gap,
                width: cellWidth,
                height: cellHeight
            )
            (busy.contains(index) ? headerBlue : NSColor(calibratedWhite: 0.86, alpha: 1)).setFill()
            let cellRadius = min(cellWidth, cellHeight) * 0.25
            NSBezierPath(roundedRect: cell, xRadius: cellRadius, yRadius: cellRadius).fill()
        }
    }

    let baseFont = NSFont.systemFont(ofSize: size * 0.25, weight: .heavy)
    let roundedFont = baseFont.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: size * 0.25) } ?? baseFont
    let superscript = "2" as NSString
    let superscriptAttributes: [NSAttributedString.Key: Any] = [.font: roundedFont, .foregroundColor: amber]
    let superscriptSize = superscript.size(withAttributes: superscriptAttributes)
    superscript.draw(
        at: NSPoint(x: page.maxX + size * 0.025, y: page.maxY - superscriptSize.height * 0.62),
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
