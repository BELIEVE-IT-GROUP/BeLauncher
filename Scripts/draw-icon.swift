// Fallback app icon, drawn in code so the build never ships a blank tile.
// The mark is the BeLauncher glyph: a chevron over a command bar, with the fixed cyan dot.
// Replace it by dropping real artwork at Resources/AppIcon-1024.png.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side))

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

// Tile: Believe blue, squircle, inset so the shadowless edge breathes like other macOS icons.
let inset: CGFloat = side * 0.085
let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let squircle = NSBezierPath(roundedRect: tile, xRadius: side * 0.225, yRadius: side * 0.225)
context.saveGState()
squircle.addClip()
let blue = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(srgbRed: 0.047, green: 0.231, blue: 0.725, alpha: 1).cgColor,  // #0C3BB9
        NSColor(srgbRed: 0.020, green: 0.047, blue: 0.161, alpha: 1).cgColor,  // #050C29
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    blue,
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)
context.restoreGState()

// Rim light in Cyan 400.
context.setStrokeColor(NSColor(srgbRed: 0, green: 0.667, blue: 1, alpha: 0.85).cgColor)
context.setLineWidth(side * 0.012)
context.addPath(squircle.cgPath)
context.strokePath()

let paper = NSColor(srgbRed: 0.980, green: 0.980, blue: 0.969, alpha: 1)
let stroke = side * 0.085
let centerX = side / 2

// Chevron: launch.
context.setStrokeColor(paper.cgColor)
context.setLineWidth(stroke)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: centerX - side * 0.16, y: side * 0.535))
context.addLine(to: CGPoint(x: centerX, y: side * 0.665))
context.addLine(to: CGPoint(x: centerX + side * 0.16, y: side * 0.535))
context.strokePath()

// Command bar.
let bar = CGRect(x: centerX - side * 0.20, y: side * 0.345, width: side * 0.40, height: side * 0.085)
context.setFillColor(paper.cgColor)
context.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
context.fillPath()

// The fixed cyan signature dot.
context.setFillColor(NSColor(srgbRed: 0, green: 0.667, blue: 1, alpha: 1).cgColor)
context.fillEllipse(in: CGRect(x: centerX + side * 0.175, y: side * 0.3475, width: side * 0.08, height: side * 0.08))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: output))
