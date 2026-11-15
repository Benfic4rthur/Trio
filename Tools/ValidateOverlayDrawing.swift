import AppKit
import TrioCore

/// Offscreen test of the real view's drawing; no foreign windows or screenshots.
@main struct ValidateOverlayDrawing {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let mask = CGRect(x: 1, y: 50, width: 81, height: 60)
        let circles = [23.0, 46.0, 69.0].map { CGRect(x: $0-10.4, y: 80-10.4, width: 20.8, height: 20.8) }
        let layout = ControlLayout(frame: mask, circles: circles, effectiveScale: 1.3)
        let view = TrioControlsView(frame: .zero)
        view.frame.origin = CGPoint(x: 4, y: -5)
        view.configure(layout: layout, mask: mask)
        let zeroOrigin = view.frame.origin == .zero
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 162, pixelsHigh: 120,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = mask.size
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        func draw() -> Data {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.saveGState(); context.cgContext.scaleBy(x: 2, y: 2)
            view.draw(view.bounds)
            context.cgContext.restoreGState(); context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let original = draw()
        for index in [0, 1, 2, 0, 2] {
            view.hover = index
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            _ = draw()
        }
        view.resetHover()
        let after = draw()
        let identical = original == after
        let output = CommandLine.arguments.dropFirst().first ?? "build/drawing-check.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        print("{\"restingPixelsRestoredAfterFiveHovers\":\(identical),\"configureResetsOrigin\":\(zeroOrigin),\"output\":\"\(output)\"}")
        if !identical || !zeroOrigin { exit(2) }
    }
}
