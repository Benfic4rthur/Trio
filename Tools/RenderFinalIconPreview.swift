import AppKit

@main
struct RenderFinalIconPreview {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("docs/branding/trio-icon-final.png")
        guard let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/Trio.icns")) else {
            fatalError("The app icon is missing")
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 700,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 1200, height: 700)
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        func color(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 255)/255,
                    green: CGFloat((value >> 8) & 255)/255,
                    blue: CGFloat(value & 255)/255, alpha: 1)
        }
        func label(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
                   weight: NSFont.Weight = .regular, ink: NSColor? = nil) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: ink ?? color(0x22303D)
            ])
        }
        func card(_ frame: NSRect, fill: NSColor = .white, radius: CGFloat = 18) {
            fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        }
        color(0xF1F3F5).setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 700).fill()
        label("Trio · ícone final", x: 48, y: 621, size: 32, weight: .semibold)
        label("Símbolos de fechar, minimizar e ampliar", x: 49, y: 590, size: 16, ink: color(0x65717D))

        card(NSRect(x: 48, y: 56, width: 470, height: 500))
        label("Dock e Aplicativos", x: 76, y: 504, size: 21, weight: .semibold)
        icon.draw(in: NSRect(x: 155, y: 213, width: 256, height: 256))
        label("256 × 256", x: 244, y: 158, size: 14, ink: color(0x65717D))
        label("Arte original do aplicativo", x: 196, y: 117, size: 13, ink: color(0x65717D))

        card(NSRect(x: 542, y: 314, width: 610, height: 242))
        label("Tamanhos reais", x: 570, y: 505, size: 21, weight: .semibold)
        icon.draw(in: NSRect(x: 642, y: 388, width: 64, height: 64))
        label("64 × 64 · Dock", x: 626, y: 345, size: 13, ink: color(0x65717D))
        icon.draw(in: NSRect(x: 897, y: 356, width: 128, height: 128))
        label("128 × 128", x: 927, y: 331, size: 13, ink: color(0x65717D))

        card(NSRect(x: 542, y: 56, width: 610, height: 234))
        label("Na pasta Aplicativos", x: 570, y: 241, size: 21, weight: .semibold)
        card(NSRect(x: 570, y: 92, width: 554, height: 122), fill: color(0xF7F8FA), radius: 12)
        icon.draw(in: NSRect(x: 815, y: 133, width: 64, height: 64))
        label("Trio", x: 833, y: 107, size: 14)
        label("Representação visual com o ícone real do bundle", x: 570, y: 67, size: 12, ink: color(0x65717D))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        print(output.path)
    }
}
