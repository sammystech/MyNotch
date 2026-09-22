import AppKit

// Renders one icon PNG at a given pixel size.
// Usage: swift make_icon.swift <size> <outPath>
let size = CGFloat(Double(CommandLine.arguments[1])!)
let outPath = CommandLine.arguments[2]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let full = CGRect(x: 0, y: 0, width: size, height: size)

// Squircle clip (Apple corner ratio ≈ 0.2237).
let corner = size * 0.2237
let clip = NSBezierPath(roundedRect: full, xRadius: corner, yRadius: corner)
clip.addClip()

// Background: smooth blue "screen" gradient.
let colors = [
    NSColor(srgbRed: 0.16, green: 0.42, blue: 1.00, alpha: 1).cgColor,
    NSColor(srgbRed: 0.40, green: 0.64, blue: 1.00, alpha: 1).cgColor
]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0), options: [])

// The notch: black, flush to the top edge, rounded bottom corners.
// Trick: draw an all-rounded rect that pokes above the top edge so the
// top corners get clipped flat, leaving square top + rounded bottom.
let nW = size * 0.52
let nH = size * 0.17
let r  = nH * 0.5
let nX = (size - nW) / 2
let notchRect = CGRect(x: nX, y: size - nH, width: nW, height: nH + r)
let notch = NSBezierPath(roundedRect: notchRect, xRadius: r, yRadius: r)
NSColor.black.setFill()
notch.fill()

// Subtle glass rim on the notch.
NSColor(white: 1, alpha: 0.12).setStroke()
notch.lineWidth = max(1, size * 0.006)
notch.stroke()

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) @ \(Int(size))px")
