// Draws the app icon (1024×1024 PNG). Variants, picked by the second argument:
//   fence  — three posts and two rails on a green hill under a cream sky (first proposal)
//   gate   — a single dark gate (two posts, three rails, a diagonal brace) on cream, nothing else
//   aerial — the paddock from above: a green rounded field with a white rail ring and a gap
//   ring   — a dark ring of rails on cream with a small green field inside (badge-like)
// Usage: swift Scripts/make-icon.swift Sources/PaddockApp/Bundle/AppIcon.png [fence|gate|aerial|ring]
import AppKit

let args = CommandLine.arguments.dropFirst()
let path = args.first ?? "AppIcon.png"
let variant = args.dropFirst().first ?? "fence"
let size: CGFloat = 1024

func color(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let sky = color(0xF4F1E8), skyTop = color(0xFBFAF6)
let field = color(0x4F9A66), fieldDark = color(0x3C8253), fieldLight = color(0x6FB483)
let post = color(0x2B2A27), rail = color(0x34332F), white = color(0xFBFAF6)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("no bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

func rounded(_ r: NSRect, _ radius: CGFloat, _ c: NSColor) {
    c.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

switch variant {
case "frame":
    // A hollow rounded square: the paddock's rail, nothing inside.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let ring = NSBezierPath(roundedRect: NSRect(x: 262, y: 262, width: 500, height: 500), xRadius: 110, yRadius: 110)
    ring.lineWidth = 84; mint.setStroke(); ring.stroke()
case "frame-gate":
    // The same rail with a gap at the bottom: a gate.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let ring = NSBezierPath(roundedRect: NSRect(x: 262, y: 262, width: 500, height: 500), xRadius: 110, yRadius: 110)
    ring.lineWidth = 84; mint.setStroke(); ring.stroke()
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: NSBezierPath(rect: NSRect(x: 422, y: 180, width: 180, height: 160)), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    rounded(NSRect(x: 400, y: 214, width: 44, height: 104), 22, mint)
    rounded(NSRect(x: 580, y: 214, width: 44, height: 104), 22, mint)
case "frame-dot":
    // Hollow square with one small green light inside: a running machine in its paddock.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), rail = color(0x9AA0AA)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let ring = NSBezierPath(roundedRect: NSRect(x: 262, y: 262, width: 500, height: 500), xRadius: 110, yRadius: 110)
    ring.lineWidth = 72; rail.setStroke(); ring.stroke()
    mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 452, y: 452, width: 120, height: 120)).fill()
case "frame-double":
    // Two hollow squares, one inside the other: host and guest.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), rail = color(0x5B6270)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let outer = NSBezierPath(roundedRect: NSRect(x: 232, y: 232, width: 560, height: 560), xRadius: 120, yRadius: 120)
    outer.lineWidth = 56; rail.setStroke(); outer.stroke()
    let inner = NSBezierPath(roundedRect: NSRect(x: 372, y: 372, width: 280, height: 280), xRadius: 64, yRadius: 64)
    inner.lineWidth = 56; mint.setStroke(); inner.stroke()
case "prompt":
    // A console window with a prompt and a block cursor.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), screen = color(0x0E1116), chrome = color(0x3A3E46)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    rounded(NSRect(x: 190, y: 250, width: 644, height: 520), 56, chrome)
    rounded(NSRect(x: 214, y: 274, width: 596, height: 420), 40, screen)
    for (i, c) in [color(0xE88B7F), color(0xFEBC2E), mint].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: 240 + CGFloat(i) * 46, y: 714, width: 28, height: 28)).fill()
    }
    let chevron = NSBezierPath(); chevron.lineWidth = 52; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: 310, y: 590)); chevron.line(to: NSPoint(x: 430, y: 484)); chevron.line(to: NSPoint(x: 310, y: 378))
    mint.setStroke(); chevron.stroke()
    rounded(NSRect(x: 490, y: 372, width: 150, height: 52), 12, mint)
case "nodes":
    // One host, three machines hanging off it.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), dim = color(0x5B6270)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let hub = NSPoint(x: 512, y: 640)
    let leaves = [NSPoint(x: 300, y: 330), NSPoint(x: 512, y: 290), NSPoint(x: 724, y: 330)]
    for l in leaves {
        let line = NSBezierPath(); line.lineWidth = 34; line.lineCapStyle = .round
        line.move(to: hub); line.line(to: l); dim.setStroke(); line.stroke()
    }
    mint.setFill(); NSBezierPath(ovalIn: NSRect(x: hub.x - 110, y: hub.y - 110, width: 220, height: 220)).fill()
    for (i, l) in leaves.enumerated() {
        (i == 1 ? mint : dim).setFill(); NSBezierPath(ovalIn: NSRect(x: l.x - 70, y: l.y - 70, width: 140, height: 140)).fill()
    }
case "stack":
    // Three machine cards fanned out; the front one lit.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), dim = color(0x3A3E46), dim2 = color(0x4A4F58)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    rounded(NSRect(x: 332, y: 420, width: 460, height: 320), 48, dim)
    rounded(NSRect(x: 282, y: 350, width: 460, height: 320), 48, dim2)
    rounded(NSRect(x: 232, y: 280, width: 460, height: 320), 48, mint)
    rounded(NSRect(x: 292, y: 500, width: 200, height: 26), 13, color(0x1F2125).withAlphaComponent(0.55))
    rounded(NSRect(x: 292, y: 450, width: 120, height: 26), 13, color(0x1F2125).withAlphaComponent(0.55))
case "power":
    // The power symbol inside a screen outline: switch machines on and off from the Mac.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: NSPoint(x: 512, y: 500), radius: 220, startAngle: 120, endAngle: 60, clockwise: false)
    ring.lineWidth = 90; ring.lineCapStyle = .round; mint.setStroke(); ring.stroke()
    rounded(NSRect(x: 467, y: 500, width: 90, height: 290), 45, mint)
case "bento":
    // One tall tile and two small ones: a layout, not the Windows four-square.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), dim = color(0x3A3E46)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    rounded(NSRect(x: 262, y: 262, width: 230, height: 500), 48, mint)
    rounded(NSRect(x: 532, y: 532, width: 230, height: 230), 48, dim)
    rounded(NSRect(x: 532, y: 262, width: 230, height: 230), 48, dim)
case "six":
    // Three by two: six machines, two running.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), dim = color(0x3A3E46)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let lit: Set<Int> = [1, 3]
    var i = 0
    for row in 0..<2 { for col in 0..<3 {
        rounded(NSRect(x: 214 + CGFloat(col) * 206, y: 330 + CGFloat(1 - row) * 206, width: 182, height: 182), 40, lit.contains(i) ? mint : dim); i += 1
    } }
case "dots":
    // Four tiles, each with its own status light: the sidebar in miniature.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), dim = color(0x3A3E46), off = color(0xE88B7F)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let positions = [NSPoint(x: 262, y: 532), NSPoint(x: 532, y: 532), NSPoint(x: 262, y: 262), NSPoint(x: 532, y: 262)]
    let lights = [mint, mint, off, mint]
    for (i, p) in positions.enumerated() {
        rounded(NSRect(x: p.x, y: p.y, width: 230, height: 230), 40, dim)
        lights[i].setFill(); NSBezierPath(ovalIn: NSRect(x: p.x + 150, y: p.y + 150, width: 44, height: 44)).fill()
        rounded(NSRect(x: p.x + 36, y: p.y + 40, width: 110, height: 16), 8, color(0x5B6270))
        rounded(NSRect(x: p.x + 36, y: p.y + 72, width: 70, height: 16), 8, color(0x5B6270))
    }
case "stagger":
    // Three tiles stepping down like a staircase, the top one lit.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), dim = color(0x3A3E46)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    rounded(NSRect(x: 250, y: 560, width: 250, height: 200), 44, mint)
    rounded(NSRect(x: 387, y: 412, width: 250, height: 200), 44, dim)
    rounded(NSRect(x: 524, y: 264, width: 250, height: 200), 44, dim)
case "mono-p":
    // A heavy rounded P, mint on charcoal.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let stem = NSBezierPath(roundedRect: NSRect(x: 330, y: 230, width: 120, height: 560), xRadius: 40, yRadius: 40)
    mint.setFill(); stem.fill()
    let bowl = NSBezierPath()
    bowl.appendArc(withCenter: NSPoint(x: 520, y: 620), radius: 170, startAngle: 90, endAngle: -90, clockwise: true)
    bowl.lineWidth = 120; bowl.lineCapStyle = .round; mint.setStroke(); bowl.stroke()
    rounded(NSRect(x: 390, y: 450, width: 150, height: 120), 0, mint)
    rounded(NSRect(x: 390, y: 670, width: 150, height: 120), 0, mint)
case "horseshoe":
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let shoe = NSBezierPath()
    shoe.appendArc(withCenter: NSPoint(x: 512, y: 560), radius: 230, startAngle: 215, endAngle: -35, clockwise: true)
    shoe.lineWidth = 96; shoe.lineCapStyle = .round; mint.setStroke(); shoe.stroke()
    for p in [NSPoint(x: 512, y: 790), NSPoint(x: 330, y: 660), NSPoint(x: 694, y: 660), NSPoint(x: 300, y: 470), NSPoint(x: 724, y: 470)] {
        charcoal.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)).fill()
    }
case "tiles":
    // Four VM tiles; one lit green = running, the others dim.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), dim = color(0x3A3E46)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    let positions = [NSPoint(x: 262, y: 532), NSPoint(x: 532, y: 532), NSPoint(x: 262, y: 262), NSPoint(x: 532, y: 262)]
    for (i, p) in positions.enumerated() {
        rounded(NSRect(x: p.x, y: p.y, width: 230, height: 230), 48, i == 1 ? mint : dim)
    }
case "servers":
    // Three server slabs, one status light each: two green, one dim.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), slab = color(0x3A3E46), dim = color(0x5B6270)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    for (i, y) in [CGFloat(620), 452, 284].enumerated() {
        rounded(NSRect(x: 232, y: y, width: 560, height: 128), 28, slab)
        let light = i == 2 ? dim : mint
        light.setFill(); NSBezierPath(ovalIn: NSRect(x: 700, y: y + 44, width: 40, height: 40)).fill()
        rounded(NSRect(x: 280, y: y + 54, width: 220, height: 20), 10, color(0x5B6270))
    }
case "dark-fence":
    // Charcoal squircle, mint fence, a low field band: the app's own dark look.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), mintDark = color(0x4F9A66)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    rounded(NSRect(x: 100, y: 100, width: 824, height: 300), 0, mintDark.withAlphaComponent(0.35))
    NSGraphicsContext.current?.restoreGraphicsState()
    for x: CGFloat in [268, 512, 756] { rounded(NSRect(x: x - 27, y: 300, width: 54, height: 330), 14, mint) }
    for y: CGFloat in [520, 400] { rounded(NSRect(x: 200, y: y - 20, width: 624, height: 40), 12, mint) }
case "dark-gate":
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    rounded(NSRect(x: 262, y: 262, width: 70, height: 500), 18, mint)
    rounded(NSRect(x: 692, y: 262, width: 70, height: 500), 18, mint)
    for y: CGFloat in [660, 512, 364] { rounded(NSRect(x: 280, y: y - 24, width: 464, height: 48), 14, mint) }
    let brace = NSBezierPath(); brace.lineWidth = 44; brace.lineCapStyle = .round
    brace.move(to: NSPoint(x: 330, y: 376)); brace.line(to: NSPoint(x: 694, y: 648)); mint.setStroke(); brace.stroke()
case "dark-screen":
    // A console screen with a fence drawn in it: what the app actually shows.
    let charcoal = color(0x1F2125), charcoalTop = color(0x2A2D33), mint = color(0x7DD98C), screen = color(0x0E1116)
    NSGradient(starting: charcoalTop, ending: charcoal)!.draw(in: squircle, angle: -90)
    rounded(NSRect(x: 190, y: 290, width: 644, height: 440), 36, color(0x3A3E46))
    rounded(NSRect(x: 214, y: 314, width: 596, height: 392), 22, screen)
    rounded(NSRect(x: 452, y: 232, width: 120, height: 60), 14, color(0x3A3E46))
    rounded(NSRect(x: 380, y: 206, width: 264, height: 34), 12, color(0x3A3E46))
    for x: CGFloat in [360, 512, 664] { rounded(NSRect(x: x - 18, y: 400, width: 36, height: 220), 10, mint) }
    for y: CGFloat in [552, 468] { rounded(NSRect(x: 320, y: y - 13, width: 384, height: 26), 8, mint) }
case "gate":
    NSGradient(starting: skyTop, ending: sky)!.draw(in: squircle, angle: -90)
    // Two posts, three rails, one brace: the whole gate centred, generous margins.
    rounded(NSRect(x: 262, y: 262, width: 70, height: 500), 18, post)
    rounded(NSRect(x: 692, y: 262, width: 70, height: 500), 18, post)
    for y: CGFloat in [660, 512, 364] { rounded(NSRect(x: 280, y: y - 24, width: 464, height: 48), 14, rail) }
    let brace = NSBezierPath()
    brace.lineWidth = 44; brace.lineCapStyle = .round
    brace.move(to: NSPoint(x: 330, y: 376)); brace.line(to: NSPoint(x: 694, y: 648))
    rail.setStroke(); brace.stroke()
case "aerial":
    NSGradient(starting: skyTop, ending: sky)!.draw(in: squircle, angle: -90)
    // The field: a rounded rectangle of grass, a white rail ring inset, a gate gap at the bottom.
    let fieldRect = NSRect(x: 190, y: 190, width: 644, height: 644)
    NSGradient(starting: fieldLight, ending: field)!.draw(in: NSBezierPath(roundedRect: fieldRect, xRadius: 120, yRadius: 120), angle: -90)
    let ring = NSBezierPath(roundedRect: fieldRect.insetBy(dx: 70, dy: 70), xRadius: 70, yRadius: 70)
    ring.lineWidth = 34
    white.setStroke(); ring.stroke()
    // The gap (gate) in the bottom rail, with two posts either side.
    rounded(NSRect(x: 430, y: 236, width: 164, height: 44), 0, field)
    rounded(NSRect(x: 404, y: 222, width: 36, height: 72), 10, white)
    rounded(NSRect(x: 584, y: 222, width: 36, height: 72), 10, white)
case "ring":
    NSGradient(starting: skyTop, ending: sky)!.draw(in: squircle, angle: -90)
    let inner = NSRect(x: 262, y: 262, width: 500, height: 500)
    NSGradient(starting: fieldLight, ending: field)!.draw(in: NSBezierPath(roundedRect: inner, xRadius: 110, yRadius: 110), angle: -90)
    let ring = NSBezierPath(roundedRect: inner.insetBy(dx: -40, dy: -40), xRadius: 150, yRadius: 150)
    ring.lineWidth = 40
    rail.setStroke(); ring.stroke()
    for x: CGFloat in [262, 512, 762] { rounded(NSRect(x: x - 26, y: 196, width: 52, height: 110), 14, post) }
default: // fence
    NSGradient(starting: skyTop, ending: sky)!.draw(in: squircle, angle: -90)
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    let hill = NSBezierPath()
    hill.move(to: NSPoint(x: 100, y: 100))
    hill.line(to: NSPoint(x: 100, y: 430))
    hill.curve(to: NSPoint(x: 924, y: 470), controlPoint1: NSPoint(x: 380, y: 520), controlPoint2: NSPoint(x: 640, y: 390))
    hill.line(to: NSPoint(x: 924, y: 100))
    hill.close()
    NSGradient(starting: field, ending: fieldDark)!.draw(in: hill, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    for x: CGFloat in [268, 512, 756] { rounded(NSRect(x: x - 27, y: 300, width: 54, height: 330), 14, post) }
    for y: CGFloat in [520, 400] { rounded(NSRect(x: 200, y: y - 20, width: 624, height: 40), 12, rail) }
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: path))
print("wrote \(path) (\(variant))")
