import AppKit
import TrioCore

final class TrioPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ControlHitButton: NSButton {
    var context: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { context?(); return }
        super.mouseDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) { context?() }
}

/// AppKit draws the traffic lights and supplies real, accessible buttons for
/// their complete hit regions. Hover never invokes a window action.
@MainActor final class TrioControlsView: NSView {
    var onAction: ((Int) -> Void)?
    var onContext: (() -> Void)?
    var onGreenHover: (() -> Void)?
    var onHoverChange: ((Int?) -> Void)?
    var holdGreenHover = false
    var hover: Int? {
        didSet {
            guard hover != oldValue, !resettingHover else { return }
            startAnimation()
            onHoverChange?(hover)
            if hover == 2 { onGreenHover?() }
        }
    }
    private var tracking: NSTrackingArea?
    private var timer: Timer?
    private var resettingHover = false
    private var zoom = [CGFloat](repeating: 1, count: 3)
    private var hitButtons: [ControlHitButton] = []
    var circles: [CGRect] = []
    override var isFlipped: Bool { true }
    // The containing window supplies its rounded material. Declaring this
    // view opaque or filling its rectangular bounds would cover that clipping.
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (i,label) in ["Fechar pelo botão original", "Minimizar janela", "Maximizar ou restaurar janela"].enumerated() {
            let b = ControlHitButton(title: label, target: self, action: #selector(clicked(_:)))
            b.tag = i; b.isBordered = false; b.setAccessibilityLabel(label)
            b.context = { [weak self] in self?.onContext?() }
            addSubview(b); hitButtons.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    func configure(layout: ControlLayout, mask: CGRect) {
        circles = layout.circles.map { $0.offsetBy(dx: -mask.minX, dy: -mask.minY) }
        frame.size = mask.size
        for i in 0..<3 {
            let start: CGFloat = i == 0 ? 0 : (circles[i-1].midX + circles[i].midX)/2
            let end: CGFloat = i == 2 ? bounds.width : (circles[i].midX + circles[i+1].midX)/2
            hitButtons[i].frame = CGRect(x: start, y: 0, width: end-start, height: bounds.height)
        }
        needsDisplay = true
    }
    @objc private func clicked(_ sender: NSButton) {
        // The enlarged, topmost light can cover a neighboring button's cell.
        // Route a physical click to what was drawn at the pointer; keyboard and
        // Accessibility presses continue to address the actual accessible button.
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .leftMouseUp,
           event.window === window {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            if let hover, containsVisualCircle(hover, point: point) { onAction?(hover); return }
        }
        onAction?(sender.tag)
    }
    override func rightMouseDown(with event: NSEvent) { onContext?() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if holdGreenHover && hover == 2 { return }
        hover = nil
    }
    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), circles.count == 3 else { hover = nil; return }
        // Choose by the fixed centers so an enlarged red light cannot prevent
        // the pointer from reaching the yellow or green base control.
        let next = (0..<3).min(by: { abs(circles[$0].midX-p.x) < abs(circles[$1].midX-p.x) })
        if next != hover { hover = next }
    }
    private func startAnimation() {
        timer?.invalidate()
        let to: [CGFloat] = (0..<3).map { index in
            if hover == index { return 2.2 }
            if let hover, abs(hover-index) == 1 { return 1.12 }
            return 1
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            zoom = to; timer = nil; needsDisplay = true; return
        }
        // Animation exists only during the short hover transition, never idle.
        let start = ProcessInfo.processInfo.systemUptime
        let from = zoom
        let animation = Timer(timeInterval: 1/120, repeats: true) { [weak self] timer in
            // Installed only on RunLoop.main below, including mouse tracking.
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime-start)/0.22)
                let eased = CGFloat(1-pow(1-t, 3))
                self.zoom = zip(from, to).map { $0 + ($1-$0)*eased }
                self.needsDisplay = true
                if t >= 1 { timer.invalidate(); self.timer = nil }
            }
        }
        timer = animation
        RunLoop.main.add(animation, forMode: .common)
    }
    func resetHover() {
        timer?.invalidate(); timer = nil
        holdGreenHover = false
        resettingHover = true; hover = nil; resettingHover = false
        zoom = [1,1,1]; needsDisplay = true
    }

    private func visualCircle(_ index: Int) -> CGRect {
        guard circles.indices.contains(index) else { return .zero }
        let base = circles[index]
        let d = max(0, min(base.width*zoom[index], bounds.height-4, bounds.width-4))
        let centerX = max(d/2+2, min(bounds.width-d/2-2, base.midX))
        let centerY = max(d/2+2, min(bounds.height-d/2-2, base.midY))
        return CGRect(x: centerX-d/2, y: centerY-d/2, width: d, height: d)
    }

    private func containsVisualCircle(_ index: Int, point: CGPoint) -> Bool {
        let circle = visualCircle(index)
        guard circle.width > 0, circle.height > 0 else { return false }
        let dx = (point.x-circle.midX)/(circle.width/2)
        let dy = (point.y-circle.midY)/(circle.height/2)
        return dx*dx + dy*dy <= 1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard circles.count == 3 else { return }
        var order = [0,1,2]
        if let hover { order.removeAll(where: { $0 == hover }); order.append(hover) }
        for i in order {
            // The enlarged light remains inside the measured safe mask. At the
            // two ends it moves inward rather than extending onto a toolbar.
            let r = visualCircle(i)
            // Match the native traffic-light RGB values in an explicit sRGB
            // space. Generic calibrated RGB made these look washed out beside
            // the system controls on wide-gamut displays.
            let color = [NSColor(srgbRed: 1, green: 95/255, blue: 87/255, alpha: 1),
                         NSColor(srgbRed: 1, green: 188/255, blue: 46/255, alpha: 1),
                         NSColor(srgbRed: 40/255, green: 200/255, blue: 64/255, alpha: 1)][i]
            let shape = NSBezierPath(ovalIn: r)
            color.setFill(); shape.fill()
            NSColor.black.withAlphaComponent(0.12).setStroke(); shape.lineWidth = 0.7; shape.stroke()
            drawSymbol(i, in: r)
        }
    }
    private func drawSymbol(_ i: Int, in r: CGRect) {
        let p = NSBezierPath(); p.lineWidth = max(1.3, r.width*0.065); p.lineCapStyle = .round; p.lineJoinStyle = .round
        let c = CGPoint(x: r.midX, y: r.midY), a = r.width*0.18
        if i == 0 {
            p.move(to: CGPoint(x:c.x-a,y:c.y-a)); p.line(to: CGPoint(x:c.x+a,y:c.y+a))
            p.move(to: CGPoint(x:c.x+a,y:c.y-a)); p.line(to: CGPoint(x:c.x-a,y:c.y+a))
        } else if i == 1 {
            p.move(to: CGPoint(x:c.x-a,y:c.y)); p.line(to: CGPoint(x:c.x+a,y:c.y))
        } else {
            // Match the native macOS full-screen mark: two separate filled
            // triangles, with no diagonal stem joining them.
            p.move(to: CGPoint(x:c.x-a,y:c.y+a))
            p.line(to: CGPoint(x:c.x+a*0.25,y:c.y+a))
            p.line(to: CGPoint(x:c.x-a,y:c.y-a*0.25))
            p.close()
            p.move(to: CGPoint(x:c.x+a,y:c.y-a))
            p.line(to: CGPoint(x:c.x-a*0.25,y:c.y-a))
            p.line(to: CGPoint(x:c.x+a,y:c.y+a*0.25))
            p.close()
            NSColor.black.withAlphaComponent(0.58).setFill()
            p.fill()
            return
        }
        NSColor.black.withAlphaComponent(0.58).setStroke(); p.stroke()
    }
}
