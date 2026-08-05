// Takes generated icon artwork that sits on a flat background and produces a macOS-ready
// 1024×1024 PNG: the tile is detected, cropped, masked to a squircle (which removes the
// glow around it) and re-centred with the padding Apple's icons use.
//
//   swift Scripts/trim-icon.swift in.png out.png
import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 2,
      let source = NSImage(contentsOfFile: arguments[1]),
      let sourceBitmap = NSBitmapImageRep(data: source.tiffRepresentation!) else {
    FileHandle.standardError.write(Data("usage: trim-icon.swift <in.png> <out.png>\n".utf8))
    exit(1)
}

let width = sourceBitmap.pixelsWide
let height = sourceBitmap.pixelsHigh

func colour(_ x: Int, _ y: Int) -> NSColor {
    sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
}

/// The tile is strongly saturated; the background and the soft glow around it are not.
func isTile(_ x: Int, _ y: Int) -> Bool {
    let c = colour(x, y)
    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
    c.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    return alpha > 0.5 && saturation > 0.55 && brightness > 0.18
}

// Scan the middle row and column: the tile is centred, the glow is not saturated enough.
var minX = width, maxX = 0, minY = height, maxY = 0
for y in stride(from: 0, to: height, by: 2) {
    for x in stride(from: 0, to: width, by: 2) where isTile(x, y) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else {
    FileHandle.standardError.write(Data("could not find the tile in the artwork\n".utf8))
    exit(1)
}

// Square it up around the detected centre.
let side = max(maxX - minX, maxY - minY) + 1
let centreX = (minX + maxX) / 2
let centreY = (minY + maxY) / 2
let crop = CGRect(
    x: CGFloat(centreX) - CGFloat(side) / 2,
    y: CGFloat(centreY) - CGFloat(side) / 2,
    width: CGFloat(side), height: CGFloat(side)
)
print("tile detected: \(side)×\(side) at (\(Int(crop.minX)), \(Int(crop.minY)))")

let canvas: CGFloat = 1024
let inset: CGFloat = canvas * 0.086            // matches the padding of stock macOS icons
let target = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)

let output = NSImage(size: NSSize(width: canvas, height: canvas))
output.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

// Squircle mask: clips the glow that surrounds the tile in the source artwork.
let mask = NSBezierPath(roundedRect: target, xRadius: canvas * 0.2237, yRadius: canvas * 0.2237)
mask.addClip()
source.draw(in: target, from: crop, operation: .copy, fraction: 1.0)
output.unlockFocus()

guard let tiff = output.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: arguments[2]))
print("wrote \(arguments[2])")
