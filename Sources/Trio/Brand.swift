import AppKit

@MainActor
enum TrioBrand {
    /// Vector template artwork remains sharp at every menu-bar backing scale.
    static func menuIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let window = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 14),
                                      xRadius: 2.5, yRadius: 2.5)
            window.lineWidth = 1.2
            window.stroke()

            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: 1.6, y: 8.5))
            separator.line(to: NSPoint(x: 16.4, y: 8.5))
            separator.lineWidth = 0.9
            separator.stroke()

            for x: CGFloat in [4.3, 8.1, 11.9] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: 10.1, width: 2.2, height: 2.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Trio"
        return image
    }
}
