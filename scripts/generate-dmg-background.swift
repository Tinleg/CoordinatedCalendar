#!/usr/bin/env swift

// Renders Packaging/dmg-background.tiff, the picture behind the disk image's Finder window: an arrow from
// the app to the Applications shortcut, and one line saying what to do. 1x and 2x in one TIFF, so it is
// sharp on Retina displays. Run from the repository root; scripts/make-dmg.sh places the icons to match.
//
// The background is light on purpose: Finder draws the icon labels itself, in black, and they would
// disappear on the navy of the icon and social preview.

import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let packagingURL = rootURL.appendingPathComponent("Packaging")

// Must match make-dmg.sh: window content 660×400 points, icons centred at x 170 and 490, y 185 from the top.
let width = 660.0, height = 400.0
let appX = 170.0, applicationsX = 490.0, iconsFromTop = 185.0

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pixels = NSSize(width: width * scale, height: height * scale)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: width, height: height)  // points, so drawing below is in points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.975, green: 0.970, blue: 0.955, alpha: 1),
        NSColor(calibratedRed: 0.930, green: 0.935, blue: 0.950, alpha: 1)
    ])?.draw(in: bounds, angle: -90)

    // The arrow, between the two icons at their height (AppKit measures y from the bottom).
    let arrowY = height - iconsFromTop
    let amber = NSColor(calibratedRed: 0.96, green: 0.64, blue: 0.10, alpha: 1)
    amber.setStroke()
    amber.setFill()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: appX + 88, y: arrowY))
    shaft.line(to: NSPoint(x: applicationsX - 100, y: arrowY))
    shaft.lineWidth = 7
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: applicationsX - 78, y: arrowY))
    head.line(to: NSPoint(x: applicationsX - 104, y: arrowY + 17))
    head.line(to: NSPoint(x: applicationsX - 104, y: arrowY - 17))
    head.close()
    head.fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSAttributedString(
        string: "Drag CoordinatedCalendar to Applications to install it",
        attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.33, alpha: 1),
            .paragraphStyle: paragraph
        ]
    )
    text.draw(in: NSRect(x: 0, y: 58, width: width, height: 24))

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let reps = [render(scale: 1), render(scale: 2)]
guard let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 0) else {
    fatalError("Could not encode the background")
}
let outputURL = packagingURL.appendingPathComponent("dmg-background.tiff")
try tiff.write(to: outputURL)
if let png = reps[1].representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dmg-background-preview.png"))
}
print("Wrote \(outputURL.path)")
