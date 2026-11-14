import AppKit

/// Uses the shipping AppKit menu artwork and app PNG without altering either.
@main
struct RenderBrandPreview {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("docs/branding", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/TrioIcon.png")) else {
            fatalError("Resources/TrioIcon.png is missing")
        }
        let width = 1200, height = 640
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        func label(_ text: String, at point: NSPoint, size: CGFloat,
                   weight: NSFont.Weight = .regular, ink: NSColor = .labelColor) {
            (text as NSString).draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink
            ])
        }
        func rounded(_ rect: NSRect, fill: NSColor, radius: CGFloat = 16) {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        func menuGlyph(in rect: NSRect, ink: NSColor) {
            let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { bounds in
                TrioBrand.menuIcon().draw(in: bounds)
                ink.setFill()
                bounds.fill(using: .sourceIn)
                return true
            }
            image.draw(in: rect)
        }

        color(0xF2F3F5).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        label("Trio", at: NSPoint(x: 48, y: 560), size: 34, weight: .semibold, ink: color(0x202B36))
        label("Identidade visual para macOS", at: NSPoint(x: 49, y: 531), size: 16, ink: color(0x66717D))

        rounded(NSRect(x: 48, y: 48, width: 500, height: 450), fill: .white)
        label("Dock e Aplicativos", at: NSPoint(x: 76, y: 450), size: 21, weight: .semibold, ink: color(0x202B36))
        icon.draw(in: NSRect(x: 170, y: 143, width: 256, height: 256))
        label("Ícone do aplicativo · 256 × 256", at: NSPoint(x: 181, y: 99), size: 13, ink: color(0x68737D))

        rounded(NSRect(x: 572, y: 48, width: 580, height: 450), fill: .white)
        label("Barra de menus", at: NSPoint(x: 600, y: 450), size: 21, weight: .semibold, ink: color(0x202B36))
        label("Tamanho real · 18 × 16 pt", at: NSPoint(x: 600, y: 414), size: 13, ink: color(0x68737D))
        rounded(NSRect(x: 600, y: 352, width: 246, height: 46), fill: color(0xEDF0F3), radius: 9)
        rounded(NSRect(x: 870, y: 352, width: 254, height: 46), fill: color(0x2C3138), radius: 9)
        menuGlyph(in: NSRect(x: 714, y: 367, width: 18, height: 16), ink: color(0x20252B))
        menuGlyph(in: NSRect(x: 988, y: 367, width: 18, height: 16), ink: .white)

        label("Ampliação 3×", at: NSPoint(x: 600, y: 304), size: 13, ink: color(0x68737D))
        rounded(NSRect(x: 600, y: 134, width: 246, height: 152), fill: color(0xEDF0F3), radius: 12)
        rounded(NSRect(x: 870, y: 134, width: 254, height: 152), fill: color(0x2C3138), radius: 12)
        menuGlyph(in: NSRect(x: 696, y: 186, width: 54, height: 48), ink: color(0x20252B))
        menuGlyph(in: NSRect(x: 970, y: 186, width: 54, height: 48), ink: .white)
        label("Claro", at: NSPoint(x: 707, y: 151), size: 12, ink: color(0x68737D))
        label("Escuro", at: NSPoint(x: 978, y: 151), size: 12, ink: color(0xD2D8DF))
        label("Símbolo monocromático adaptado pelo sistema", at: NSPoint(x: 600, y: 99), size: 13, ink: color(0x68737D))

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("preview.png"))
        print(output.appendingPathComponent("preview.png").path)
    }
}
