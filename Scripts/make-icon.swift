import AppKit
import Foundation

// Renders the app icon master PNG (2048×2048).
//
// Design: macOS squircle with a flat indigo base and a centered, white cobra
// silhouette. The cobra artwork is a modified copy of the "Cobra" icon by
// Delapouite (game-icons.net), licensed CC BY 3.0; the source file lives at
// Resources/snake-cobra.svg. Modifications: removed the square background
// plate, dropped the original fill color, and scaled it for the icon grid.

let logical: CGFloat = 1024
let scale: CGFloat = 2 // render at 2048 for crisp 512@2x
let size = logical * scale
let canvas = NSSize(width: size, height: size)

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x * scale, y: y * scale)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let svgURL = output.deletingLastPathComponent().appendingPathComponent("snake-cobra.svg")

guard let svg = NSImage(contentsOf: svgURL) else {
    fatalError("Could not read \(svgURL.path)")
}

// Render the SVG into a transparent bitmap and turn every opaque pixel white,
// so the artwork works as a monochrome mark on the indigo tile.
let svgPixels = 2048
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: svgPixels, pixelsHigh: svgPixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Could not create bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: svgPixels, height: svgPixels).fill()
svg.draw(in: NSRect(x: 0, y: 0, width: svgPixels, height: svgPixels),
         from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let raw = rep.bitmapData else { fatalError("No bitmap data") }
let bytesPerRow = rep.bytesPerRow

// Tint: keep alpha, force RGB to white.
for y in 0..<svgPixels {
    let row = raw.advanced(by: y * bytesPerRow)
    for x in 0..<svgPixels {
        let p = row.advanced(by: x * 4)
        p[0] = 255
        p[1] = 255
        p[2] = 255
    }
}

// Tight crop bounds of the artwork so it can be optically centered.
var minX = svgPixels, minY = svgPixels, maxX = -1, maxY = -1
for y in 0..<svgPixels {
    let row = raw.advanced(by: y * bytesPerRow)
    for x in 0..<svgPixels {
        if row[x * 4 + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard maxX >= minX, maxY >= minY else { fatalError("Empty artwork") }
let artWidth = CGFloat(maxX - minX + 1)
let artHeight = CGFloat(maxY - minY + 1)

let image = NSImage(size: canvas)
image.lockFocus()

// Squircle backdrop — content on the 1024 canvas is inset like Apple's grid.
let inset: CGFloat = 100
let rect = NSRect(x: inset * scale, y: inset * scale,
                  width: (logical - inset * 2) * scale,
                  height: (logical - inset * 2) * scale)
let radius: CGFloat = 190 * scale
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let baseColor = NSColor(srgbRed: 79.0 / 255.0, green: 70.0 / 255.0, blue: 229.0 / 255.0, alpha: 1)
baseColor.setFill()
squircle.fill()

// Artwork height is 62% of the tile; width follows the original proportions.
let targetHeight = 640 * scale
let targetWidth = targetHeight * (artWidth / artHeight)
let targetRect = NSRect(
    x: (size - targetWidth) / 2,
    y: (size - targetHeight) / 2,
    width: targetWidth,
    height: targetHeight
)

if let cg = rep.cgImage {
    let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    NSGraphicsContext.current?.cgContext.interpolationQuality = .high
    if let cropped {
        NSGraphicsContext.current?.cgContext.draw(cropped, in: targetRect)
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render PNG")
}
try png.write(to: output)
print("Wrote \(output.path) (\(Int(size))×\(Int(size)))")
