import AppKit

// Own vector drawing inspired by a dark macOS title bar. No screenshot is modified.
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("docs/previews", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func tint(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
          color: NSColor = .white, weight: NSFont.Weight = .regular) {
    (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
    ])
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func symbol(_ index: Int, center: NSPoint, diameter: CGFloat) {
    let path = NSBezierPath()
    let r = diameter * 0.145
    path.lineWidth = max(0.8, diameter * 0.055)
    path.lineCapStyle = .round
    tint(0x382B25, alpha: 0.82).setStroke()
    switch index {
    case 0:
        path.move(to: NSPoint(x: center.x-r, y: center.y-r))
        path.line(to: NSPoint(x: center.x+r, y: center.y+r))
        path.move(to: NSPoint(x: center.x-r, y: center.y+r))
        path.line(to: NSPoint(x: center.x+r, y: center.y-r))
    case 1:
        path.move(to: NSPoint(x: center.x-r, y: center.y))
        path.line(to: NSPoint(x: center.x+r, y: center.y))
    default:
        path.move(to: NSPoint(x: center.x-r, y: center.y+r))
        path.line(to: NSPoint(x: center.x-r, y: center.y+r*0.1))
        path.move(to: NSPoint(x: center.x-r, y: center.y+r))
        path.line(to: NSPoint(x: center.x-r*0.1, y: center.y+r))
        path.move(to: NSPoint(x: center.x+r, y: center.y-r))
        path.line(to: NSPoint(x: center.x+r, y: center.y-r*0.1))
        path.move(to: NSPoint(x: center.x+r, y: center.y-r))
        path.line(to: NSPoint(x: center.x+r*0.1, y: center.y-r))
        path.move(to: NSPoint(x: center.x-r, y: center.y+r))
        path.line(to: NSPoint(x: center.x-r*0.15, y: center.y+r*0.15))
        path.move(to: NSPoint(x: center.x+r, y: center.y-r))
        path.line(to: NSPoint(x: center.x+r*0.15, y: center.y-r*0.15))
    }
    path.stroke()
}

func controls(scale: CGFloat, origin: NSPoint, hovered: Int? = nil, native: Bool = false) {
    let diameter = 12 * scale
    let spacing: CGFloat = native ? 23 : diameter + 2
    let centers = (0..<3).map { NSPoint(x: origin.x + CGFloat($0) * spacing, y: origin.y) }
    let tops: [UInt32] = [0xFF897B, 0xFFD754, 0x56D95B]
    let bottoms: [UInt32] = [0xFF5C54, 0xFFBE2F, 0x28C840]
    var order = [0, 1, 2]
    if let hovered { order.removeAll { $0 == hovered }; order.append(hovered) }
    for i in order {
        let multiplier: CGFloat
        if let hovered {
            let distance = abs(i-hovered)
            multiplier = distance == 0 ? 2 : (distance == 1 ? 1.35 : 1.08)
        } else { multiplier = 1 }
        let d = diameter * multiplier
        let frame = NSRect(x: centers[i].x-d/2, y: centers[i].y-d/2, width: d, height: d)
        let shape = NSBezierPath(ovalIn: frame)
        NSGradient(starting: tint(bottoms[i]), ending: tint(tops[i]))!.draw(in: shape, angle: 90)
        tint(0x000000, alpha: 0.12).setStroke()
        shape.lineWidth = 0.65
        shape.stroke()
        if hovered != nil { symbol(i, center: centers[i], diameter: d) }
    }
}

func titlebar(rect: NSRect, scale: CGFloat, native: Bool = false) {
    rounded(rect, radius: 12, fill: tint(0x272729))
    let chrome = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
    tint(0x454548).setStroke()
    chrome.lineWidth = 1
    chrome.stroke()
    let diameter: CGFloat = native ? 12 : 12 * scale
    let start = NSPoint(x: rect.minX + 17 + diameter/2, y: rect.midY + 6)
    controls(scale: scale, origin: start, native: native)
    // A nearby toolbar arrow makes the reserved-space question visible in the study.
    let groupEnd = native ? start.x + 46 + 6 : start.x + 2*(diameter+2) + diameter/2
    let arrowX = max(rect.minX + 110, groupEnd + 30)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: arrowX+7, y: start.y))
    arrow.line(to: NSPoint(x: arrowX-7, y: start.y))
    arrow.move(to: NSPoint(x: arrowX-7, y: start.y))
    arrow.line(to: NSPoint(x: arrowX-1, y: start.y+6))
    arrow.move(to: NSPoint(x: arrowX-7, y: start.y))
    arrow.line(to: NSPoint(x: arrowX-1, y: start.y-6))
    tint(0xA0A0A4).setStroke()
    arrow.lineWidth = 1.25
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()
}

func render(width: CGFloat, height: CGFloat, name: String, draw: () -> Void) throws {
    let pixelsWide = Int(width * 2), pixelsHigh = Int(height * 2)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    tint(0x18181A).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw()
    NSGraphicsContext.current!.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

for scale in 2...5 {
    try render(width: 640, height: 360, name: "trio-\(scale)x.png") {
        text("Trio · \(scale)×", x: 28, y: 308, size: 25, weight: .semibold)
        text("Atual · 1×", x: 28, y: 269, size: 13, color: tint(0xBDBDC2), weight: .medium)
        titlebar(rect: NSRect(x: 28, y: 199, width: 584, height: 60), scale: 1, native: true)
        text("Trio · \(scale)×", x: 28, y: 166, size: 13, color: tint(0xBDBDC2), weight: .medium)
        titlebar(rect: NSRect(x: 28, y: 63, width: 584, height: 92), scale: CGFloat(scale))
        text("Estudo visual — altura e encaixe ainda serão validados.", x: 28, y: 23, size: 12, color: tint(0x929298))
    }
}

try render(width: 1280, height: 780, name: "trio-sizes.png") {
    text("Trio · escolha o tamanho", x: 28, y: 728, size: 25, weight: .semibold)
    text("O tamanho original aparece acima de cada proposta.", x: 28, y: 700,
         size: 14, color: tint(0xBDBDC2))
    for (index, scale) in (2...5).enumerated() {
        let x: CGFloat = index % 2 == 0 ? 28 : 654
        let y: CGFloat = index < 2 ? 378 : 72
        text("\(scale)×", x: x, y: y+254, size: 20, weight: .semibold)
        text("Atual · 1×", x: x, y: y+224, size: 12, color: tint(0xBDBDC2))
        titlebar(rect: NSRect(x: x, y: y+155, width: 598, height: 60), scale: 1, native: true)
        text("Trio · \(scale)×", x: x, y: y+125, size: 12, color: tint(0xBDBDC2))
        titlebar(rect: NSRect(x: x, y: y+20, width: 598, height: 92), scale: CGFloat(scale))
    }
    text("Estudo visual — altura e encaixe ainda serão validados.", x: 28, y: 28,
         size: 12, color: tint(0x929298))
}

try render(width: 1280, height: 940, name: "trio-wave.png") {
    text("Trio · ampliação em onda", x: 28, y: 885, size: 25, weight: .semibold)
    text("Ao passar o mouse, o controle cresce até 2×. Os vizinhos acompanham suavemente.",
         x: 28, y: 857, size: 14, color: tint(0xBDBDC2))
    let labels = ["Em repouso", "Sobre o vermelho", "Sobre o amarelo", "Sobre o verde"]
    let colWidth: CGFloat = 300
    for col in 0..<4 {
        text(labels[col], x: 28+CGFloat(col)*312, y: 813, size: 13, color: tint(0xD0D0D5), weight: .medium)
    }
    for (row, scale) in (2...5).enumerated() {
        let y: CGFloat = 615-CGFloat(row)*184
        for col in 0..<4 {
            let x = 28+CGFloat(col)*312
            let rect = NSRect(x: x, y: y, width: colWidth, height: 174)
            rounded(rect, radius: 12, fill: tint(0x272729))
            text("\(scale)×", x: x+14, y: y+145, size: 12, color: tint(0xA5A5AC), weight: .medium)
            let d = CGFloat(scale)*12
            let total = 3*d+4
            controls(scale: CGFloat(scale), origin: NSPoint(x: x+(colWidth-total)/2+d/2, y: y+78),
                     hovered: col == 0 ? nil : col-1)
        }
    }
    text("Estudo visual — a ampliação e as sobreposições ainda serão validadas na barra real.",
         x: 28, y: 20, size: 12, color: tint(0x929298))
}
print("Created docs/previews/trio-{2,3,4,5}x.png, trio-sizes.png, and trio-wave.png")
