// Renders the DMG window background (660x400 pt) at 1x and 2x.
// Layout must match dmg/settings.py: icon centres (180,232) and (480,232); labels land on the nameplate.
import AppKit

let W: CGFloat = 660, H: CGFloat = 400
func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // AppKit is y-up; flip so the layout reads top-down like Finder's coordinates.
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)

    // Background: near-black with a soft cool glow from the top.
    NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    let glow = NSGradient(colors: [NSColor(calibratedRed: 0.28, green: 0.32, blue: 0.48, alpha: 0.35), .clear])!
    glow.draw(fromCenter: NSPoint(x: W / 2, y: -40), radius: 0, toCenter: NSPoint(x: W / 2, y: -40), radius: 420, options: [])

    // The product's signature: a black notch hanging from the top edge.
    let notch = NSBezierPath()
    let nw: CGFloat = 196, nh: CGFloat = 30, r: CGFloat = 13
    let nx = (W - nw) / 2
    notch.move(to: NSPoint(x: nx - 10, y: 0))
    notch.curve(to: NSPoint(x: nx, y: 10), controlPoint1: NSPoint(x: nx, y: 0), controlPoint2: NSPoint(x: nx, y: 0))
    notch.line(to: NSPoint(x: nx, y: nh - r))
    notch.curve(to: NSPoint(x: nx + r, y: nh), controlPoint1: NSPoint(x: nx, y: nh), controlPoint2: NSPoint(x: nx, y: nh))
    notch.line(to: NSPoint(x: nx + nw - r, y: nh))
    notch.curve(to: NSPoint(x: nx + nw, y: nh - r), controlPoint1: NSPoint(x: nx + nw, y: nh), controlPoint2: NSPoint(x: nx + nw, y: nh))
    notch.line(to: NSPoint(x: nx + nw, y: 10))
    notch.curve(to: NSPoint(x: nx + nw + 10, y: 0), controlPoint1: NSPoint(x: nx + nw, y: 0), controlPoint2: NSPoint(x: nx + nw, y: 0))
    notch.close()
    NSColor.black.setFill(); notch.fill()

    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, y: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color, .paragraphStyle: style]
        // Draw text unflipped.
        ctx.saveGState(); ctx.translateBy(x: 0, y: y + size); ctx.scaleBy(x: 1, y: -1)
        (s as NSString).draw(in: NSRect(x: 0, y: 0, width: W, height: size * 1.4), withAttributes: attrs)
        ctx.restoreGState()
    }
    text("My Notch", 12, .semibold, NSColor(white: 1, alpha: 0.9), y: 8)
    text("Drag My Notch into Applications", 21, .semibold, .white, y: 62)
    text("Then open it from Applications — it lives in your notch.", 12.5, .regular, NSColor(white: 1, alpha: 0.5), y: 94)

    // Two glass cards; each has a mid-tone footer where Finder writes the
    // label, so the name reads in Dark Mode (white) AND Light Mode (black).
    for cx in [CGFloat(180), CGFloat(480)] {
        let card = NSRect(x: cx - 92, y: 136, width: 184, height: 196)
        let p = NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22)
        NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.1, alpha: 1)])!.draw(in: p, angle: 90)
        ctx.saveGState(); p.addClip()
        // Finder draws icon labels BLACK on a custom background (even in
        // Dark Mode), so the name sits on a light frosted nameplate.
        let plate = NSRect(x: card.minX, y: card.maxY - 50, width: card.width, height: 50)
        NSGradient(colors: [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.82, alpha: 1)])!
            .draw(in: plate, angle: -90)
        NSColor(white: 1, alpha: 0.6).setFill()
        NSRect(x: plate.minX, y: plate.minY, width: plate.width, height: 1).fill()
        ctx.restoreGState()
        NSColor(white: 1, alpha: 0.12).setStroke(); p.lineWidth = 1; p.stroke()
    }

    // Arrow between the cards.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 296, y: 222)); arrow.line(to: NSPoint(x: 360, y: 222))
    arrow.lineWidth = 3; arrow.lineCapStyle = .round
    let dash: [CGFloat] = [1, 9]; arrow.setLineDash(dash, count: 2, phase: 0)
    NSColor(white: 1, alpha: 0.45).setStroke(); arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 356, y: 211)); head.line(to: NSPoint(x: 368, y: 222)); head.line(to: NSPoint(x: 356, y: 233))
    head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round
    NSColor(white: 1, alpha: 0.8).setStroke(); head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
let dir = CommandLine.arguments[1]
render(scale: 1, to: dir + "/background.png")
render(scale: 2, to: dir + "/background@2x.png")
