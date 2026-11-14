import AppKit

private final class ArrangementRowButton: NSButton {
    private var pointerInside = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if pointerInside || cell?.isHighlighted == true {
            NSColor.labelColor.withAlphaComponent(cell?.isHighlighted == true ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A nonactivating AppKit menu. Showing it never makes Trio the frontmost app
/// and introduces no native title-bar controls of its own.
@MainActor final class ArrangementPanel: NSObject {
    var onSelect: ((Int) -> Void)?
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?
    var isVisible: Bool { panel.isVisible }
    var windowNumber: Int { panel.windowNumber }

    private let panel: TrioPanel
    private let menuSize = NSSize(width: 200, height: 160)
    private var controlsFrame = NSRect.zero
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var dismissWork: DispatchWorkItem?

    override init() {
        panel = TrioPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        super.init()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenNone]
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: menuSize))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -7)
        ])
        for (title, tag) in [("Maximizar / restaurar", 0), ("Metade esquerda", 1),
                             ("Metade direita", 2), ("Centralizar", 3)] {
            let row = makeButton(title: title, action: #selector(selectArrangement(_:)))
            row.tag = tag
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let open = makeButton(title: "Abrir Trio", action: #selector(openTrio))
        stack.addArrangedSubview(open)
        open.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = ArrangementRowButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.alignment = .left
        button.font = .systemFont(ofSize: 13)
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    /// Both frames are Cocoa screen coordinates. Prefer below the lights; if
    /// that cannot fit, use an available side without covering the controls.
    func show(below controlsFrame: NSRect, relativeTo: Int) {
        let center = NSPoint(x: controlsFrame.midX, y: controlsFrame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else {
            hide(); return
        }
        let work = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        guard work.width >= menuSize.width, work.height >= menuSize.height else { hide(); return }
        let gap: CGFloat = 6
        let x = max(work.minX, min(controlsFrame.minX, work.maxX-menuSize.width))
        let y = max(work.minY, min(controlsFrame.midY-menuSize.height/2, work.maxY-menuSize.height))
        let candidates = [
            NSRect(x: x, y: controlsFrame.minY-menuSize.height-gap, width: menuSize.width, height: menuSize.height),
            NSRect(x: x, y: controlsFrame.maxY+gap, width: menuSize.width, height: menuSize.height),
            NSRect(x: controlsFrame.maxX+gap, y: y, width: menuSize.width, height: menuSize.height),
            NSRect(x: controlsFrame.minX-menuSize.width-gap, y: y, width: menuSize.width, height: menuSize.height)
        ]
        guard let frame = candidates.first(where: {
            work.contains($0) && !$0.intersects(controlsFrame.insetBy(dx: -2, dy: -2))
        }) else { hide(); return }
        panel.setFrame(frame, display: true)
        self.controlsFrame = controlsFrame
        dismissWork?.cancel()
        dismissWork = nil
        panel.order(.above, relativeTo: relativeTo)
        installMouseMonitors()
        pointerMoved()
    }

    func hide() {
        let wasVisible = panel.isVisible
        dismissWork?.cancel()
        dismissWork = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        controlsFrame = .zero
        panel.orderOut(nil)
        if wasVisible { onDismiss?() }
    }

    private func installMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved() }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                // AppKit delivers global event-monitor handlers on the main thread.
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
        }
    }

    private func pointerMoved() {
        guard panel.isVisible else { return }
        if containsPointer() {
            dismissWork?.cancel()
            dismissWork = nil
            return
        }
        guard dismissWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dismissWork = nil
            guard self.panel.isVisible, !self.containsPointer() else { return }
            self.hide()
        }
        dismissWork = work
        // A short grace period lets the pointer cross the gap into the menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
    }

    private func containsPointer() -> Bool {
        let point = NSEvent.mouseLocation
        return controlsFrame.contains(point) || panel.frame.contains(point)
    }

    @objc private func selectArrangement(_ sender: NSButton) { hide(); onSelect?(sender.tag) }
    @objc private func openTrio() { hide(); onOpen?() }
}
