import AppKit
import ApplicationServices

enum AX {
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = value(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func string(_ element: AXUIElement, _ name: String) -> String? { value(element, name) as? String }
    static func flag(_ element: AXUIElement, _ name: String) -> Bool { (value(element, name) as? Bool) ?? false }
    static func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let rect = CGRect(origin: point, size: size)
        return validRect(rect) ? rect : nil
    }
    static func validRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite &&
        rect.size.width > 0 && rect.size.height > 0 &&
        rect.maxX.isFinite && rect.maxY.isFinite
    }
    static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }
    static func pid(_ element: AXUIElement) -> pid_t { var pid: pid_t = 0; AXUIElementGetPid(element, &pid); return pid }
    static func at(_ point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success else { return nil }
        return hit
    }
    static func setFrame(_ frame: CGRect, on element: AXUIElement) -> Bool {
        guard validRect(frame), isSettable(element, kAXPositionAttribute),
              isSettable(element, kAXSizeAttribute) else { return false }
        var origin = frame.origin, size = frame.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return false }
        // Some apps constrain a size using the previous position. Set size again after moving.
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        let sized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        return moved == .success && sized == .success
    }
    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }
}

struct SystemWindow {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let layer: Int
    static func visible() -> [SystemWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var windows: [SystemWindow] = []
        for row in list {
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  let layer = row[kCGWindowLayer as String] as? Int else {
                // A partial list could omit a covering window. An unknown
                // result must never become permission to draw or click.
                return []
            }
            // A finite zero-area window cannot cover any point. System UI
            // creates these transiently while handling ordinary clicks.
            if bounds.origin.x.isFinite, bounds.origin.y.isFinite,
               bounds.size.width.isFinite, bounds.size.height.isFinite,
               bounds.size.width == 0 || bounds.size.height == 0 { continue }
            guard AX.validRect(bounds) else { return [] }
            windows.append(SystemWindow(id: id, pid: pid, bounds: bounds, layer: layer))
        }
        return windows
    }
    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance &&
        abs(a.width-b.width) <= tolerance && abs(a.height-b.height) <= tolerance
    }
}

struct WindowTarget {
    let pid: pid_t
    let window: AXUIElement
    let id: CGWindowID
    let frame: CGRect
    let buttons: [AXUIElement]
    let buttonFrames: [CGRect]
    let name: String

    static func focused() -> WindowTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              app.activationPolicy == .regular else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute),
              AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              !AX.flag(window, kAXMinimizedAttribute), let frame = AX.rect(window) else { return nil }
        let attributes = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
        let buttons = attributes.compactMap { AX.element(window, $0) }
        guard buttons.count == 3, buttons.allSatisfy({
            AX.pid($0) == app.processIdentifier && AX.string($0, kAXRoleAttribute) == kAXButtonRole &&
            AX.flag($0, kAXEnabledAttribute)
        }) else { return nil }
        let rects = buttons.compactMap { AX.rect($0) }
        guard rects.count == 3 else { return nil }
        let matches = SystemWindow.visible().filter { $0.pid == app.processIdentifier && $0.layer == 0 && SystemWindow.close($0.bounds, frame) }
        guard matches.count == 1 else { return nil }
        // Fail closed for sheets, fullscreen windows, and inaccessible window geometry.
        guard let children = AX.value(window, kAXChildrenAttribute) as? [AXUIElement],
              !children.contains(where: { AX.string($0, kAXRoleAttribute) == kAXSheetRole }) else { return nil }
        guard let screen = screen(for: frame), !SystemWindow.close(frame, toAX(screen.frame), tolerance: 1) else { return nil }
        return WindowTarget(pid: app.processIdentifier, window: window, id: matches[0].id, frame: frame,
                            buttons: buttons, buttonFrames: rects, name: app.localizedName ?? "Aplicativo")
    }

    func isCurrent() -> Bool {
        guard let current = WindowTarget.focused() else { return false }
        return current.pid == pid && current.id == id && AX.same(current.window, window) &&
            SystemWindow.close(current.frame, frame, tolerance: 1) &&
            zip(current.buttons, buttons).allSatisfy({ AX.same($0.0, $0.1) }) &&
            zip(current.buttonFrames, buttonFrames).allSatisfy({ SystemWindow.close($0.0, $0.1, tolerance: 1) })
    }
    // No AXWindowNumber or other undocumented attributes. CG matching must be unique.
    func ownsTopmostPoint(_ point: CGPoint) -> Bool {
        let own = getpid()
        // Trio's normal-level panel cannot cover menu/Dock/accessibility
        // surfaces at higher levels. Dimming tools may expose a full-display
        // high-level window that deliberately passes clicks through. Compare
        // normal application windows here; AX hit testing must still confirm
        // the original button immediately before forwarding an action.
        guard let top = SystemWindow.visible().first(where: { $0.pid != own && $0.bounds.contains(point) && $0.layer == 0 }) else { return false }
        return top.id == id
    }
    func ownsTopmostFrame(_ proposedBounds: CGRect) -> Bool {
        guard AX.validRect(proposedBounds), frame.contains(proposedBounds) else { return false }
        let windows = SystemWindow.visible()
        guard let index = windows.firstIndex(where: { $0.id == id && $0.pid == pid }),
              SystemWindow.close(windows[index].bounds, frame, tolerance: 1) else { return false }
        // The complete mask must be unobscured, not only its three centers.
        return !windows[..<index].contains(where: {
            $0.pid != getpid() && $0.layer == 0 && $0.bounds.intersects(proposedBounds)
        })
    }
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    static func toCocoa(_ rect: CGRect) -> CGRect { toAX(rect) }
    static func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a,b in
            let aa = toAX(a.frame).intersection(rect), bb = toAX(b.frame).intersection(rect)
            return (aa.isNull ? 0 : aa.width*aa.height) < (bb.isNull ? 0 : bb.width*bb.height)
        }
    }

    /// Survey the entire largest candidate first. Every subsequent fitted
    /// layout must remain inside proposedBounds. Nil means the tree could not
    /// be inspected safely; an empty array means a completed, clear survey.
    func obstacles(for proposedBounds: CGRect) -> [CGRect]? {
        guard AX.validRect(proposedBounds), frame.contains(proposedBounds) else { return nil }
        var obstacles: [CGRect] = [], visited = 0, complete = true
        let started = ProcessInfo.processInfo.systemUptime
        let maximumDuration: TimeInterval = 0.3
        var containers: Set<String> = [kAXWindowRole, kAXGroupRole, kAXToolbarRole, kAXSplitGroupRole,
                                       kAXScrollAreaRole, kAXLayoutAreaRole, kAXListRole, kAXRadioGroupRole]
        if #available(macOS 26.0, *) {
            containers.insert(NSAccessibility.Role.webAreaRole.rawValue)
        }
        func withinBudget() -> Bool {
            visited < 400 && ProcessInfo.processInfo.systemUptime - started < maximumDuration
        }
        func walk(_ element: AXUIElement, depth: Int) {
            guard complete else { return }
            guard depth < 32, withinBudget() else { complete = false; return }
            visited += 1
            if buttons.contains(where: { AX.same($0, element) }) { return }
            guard let rect = AX.rect(element) else { complete = false; return }
            // Bounds are a conservative pruning boundary for supported AX
            // containers. Children that draw outside their container require
            // an explicit compatibility profile, outside this prototype.
            guard proposedBounds.intersects(rect) else { return }
            guard let role = AX.string(element, kAXRoleAttribute) else { complete = false; return }
            guard containers.contains(role) else {
                // Known interactive leaves, text/images and unfamiliar roles
                // all occupy space. Unknown content can never become a hole.
                obstacles.append(rect.insetBy(dx: -2, dy: -2))
                return
            }
            guard withinBudget() else { complete = false; return }
            var childrenValue: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
            guard error == .success, let children = childrenValue as? [AXUIElement] else {
                // Leaves never reach this branch. An unsupported children
                // attribute on a container cannot prove that the area is free.
                complete = false
                return
            }
            for child in children {
                walk(child, depth: depth + 1)
                if !complete { return }
            }
        }
        walk(window, depth: 0)
        return complete && ProcessInfo.processInfo.systemUptime - started < maximumDuration ? obstacles : nil
    }
}
