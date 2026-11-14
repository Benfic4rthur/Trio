import AppKit

// Reproducible local artwork; no network service, model, or external asset.
// Run from the repository root: swift Tools/GenerateIcon.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = root.appendingPathComponent("build/Trio.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func gradient(_ colors: [NSColor], in path: NSBezierPath, angle: CGFloat = 90) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}

func shadow(_ blur: CGFloat, _ offset: NSSize, _ opacity: CGFloat, drawing: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    drawing()
    NSGraphicsContext.restoreGraphicsState()
}

func artwork() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
    shadow(24, NSSize(width: 0, height: -11), 0.26) {
        color(0x202F40).setFill()
        tile.fill()
    }
    gradient([color(0x15202D), color(0x354B61), color(0x5D7386)], in: tile, angle: 64)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let halo = NSGradient(colors: [color(0xBCD9F0, 0.19), color(0x8BB1CF, 0)])!
    halo.draw(fromCenter: NSPoint(x: 240, y: 840), radius: 0,
              toCenter: NSPoint(x: 240, y: 840), radius: 850,
              options: [.drawsAfterEndingLocation])
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.21).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    // A compact window silhouette places the three controls in their natural setting.
    let window = NSBezierPath(roundedRect: NSRect(x: 150, y: 242, width: 724, height: 540), xRadius: 77, yRadius: 77)
    shadow(42, NSSize(width: 0, height: -25), 0.44) {
        gradient([color(0xA9B9C6), color(0xF3F7F9)], in: window, angle: 90)
    }
    color(0xFFFFFF, 0.73).setStroke()
    window.lineWidth = 3
    window.stroke()

    // Recessed glass below the title bar, with restrained reflections.
    let content = NSBezierPath(roundedRect: NSRect(x: 173, y: 264, width: 678, height: 304), xRadius: 56, yRadius: 56)
    gradient([color(0x6D8497), color(0xA3B8C8), color(0xD8E4EC)], in: content, angle: 54)
    color(0x172F45, 0.14).setStroke()
    content.lineWidth = 2
    content.stroke()
    NSGraphicsContext.saveGraphicsState()
    content.addClip()
    let reflection = NSBezierPath()
    reflection.move(to: NSPoint(x: 166, y: 380))
    reflection.curve(to: NSPoint(x: 861, y: 488), controlPoint1: NSPoint(x: 429, y: 590), controlPoint2: NSPoint(x: 623, y: 329))
    reflection.line(to: NSPoint(x: 861, y: 604))
    reflection.line(to: NSPoint(x: 166, y: 604))
    reflection.close()
    color(0xFFFFFF, 0.11).setFill()
    reflection.fill()
    NSGraphicsContext.restoreGraphicsState()

    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: 182, y: 581))
    divider.line(to: NSPoint(x: 842, y: 581))
    color(0x52677A, 0.14).setStroke()
    divider.lineWidth = 2
    divider.stroke()

    let lights: [(CGFloat, UInt32, UInt32)] = [
        (302, 0xFF9A84, 0xF3464B),
        (512, 0xFFDF76, 0xF2AC28),
        (722, 0x88ECA7, 0x20B96B)
    ]
    for (index, light) in lights.enumerated() {
        let (x, top, bottom) = light
        let frame = NSRect(x: x - 75, y: 601, width: 150, height: 150)
        let circle = NSBezierPath(ovalIn: frame)
        shadow(9, NSSize(width: 0, height: -6), 0.25) {
            gradient([color(bottom), color(top)], in: circle, angle: 90)
        }
        color(0x000000, 0.12).setStroke()
        circle.lineWidth = 2
        circle.stroke()
        let gloss = NSBezierPath(ovalIn: NSRect(x: x - 57, y: 675, width: 114, height: 58))
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        gradient([color(0xFFFFFF, 0), color(0xFFFFFF, 0.38)], in: gloss, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        let center = NSPoint(x: x, y: 676)
        let glyph = NSBezierPath()
        glyph.lineWidth = 9
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        switch index {
        case 0:
            glyph.move(to: NSPoint(x: center.x-22, y: center.y-22))
            glyph.line(to: NSPoint(x: center.x+22, y: center.y+22))
            glyph.move(to: NSPoint(x: center.x-22, y: center.y+22))
            glyph.line(to: NSPoint(x: center.x+22, y: center.y-22))
        case 1:
            glyph.move(to: NSPoint(x: center.x-27, y: center.y))
            glyph.line(to: NSPoint(x: center.x+27, y: center.y))
        default:
            glyph.move(to: NSPoint(x: center.x-5, y: center.y-5))
            glyph.line(to: NSPoint(x: center.x-25, y: center.y-25))
            glyph.move(to: NSPoint(x: center.x-25, y: center.y-8))
            glyph.line(to: NSPoint(x: center.x-25, y: center.y-25))
            glyph.line(to: NSPoint(x: center.x-8, y: center.y-25))
            glyph.move(to: NSPoint(x: center.x+5, y: center.y+5))
            glyph.line(to: NSPoint(x: center.x+25, y: center.y+25))
            glyph.move(to: NSPoint(x: center.x+8, y: center.y+25))
            glyph.line(to: NSPoint(x: center.x+25, y: center.y+25))
            glyph.line(to: NSPoint(x: center.x+25, y: center.y+8))
        }
        color(0x28313A, 0.84).setStroke()
        glyph.stroke()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    graphics.imageInterpolation = .high
    NSGraphicsContext.current = graphics
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    artwork()
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try png(size: 1024).write(to: resources.appendingPathComponent("TrioIcon.png"))
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try png(size: base * scale).write(to: iconset.appendingPathComponent(filename))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Trio.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed: \(task.terminationStatus)") }
print("Created Resources/TrioIcon.png and Resources/Trio.icns")
