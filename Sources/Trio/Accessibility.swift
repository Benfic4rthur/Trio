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
        return CGRect(origin: point, size: size)
    }
    static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }
    static func pid(_ element: AXUIElement) -> pid_t { var pid: pid_t = 0; AXUIElementGetPid(element, &pid); return pid }
    static func at(_ point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success else { return nil }
        return hit
    }
    static func setFrame(_ frame: CGRect, on element: AXUIElement) -> Bool {
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
        return list.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  let layer = row[kCGWindowLayer as String] as? Int else { return nil }
            return SystemWindow(id: id, pid: pid, bounds: bounds, layer: layer)
        }
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
        guard buttons.count == 3, buttons.allSatisfy({ AX.flag($0, kAXEnabledAttribute) }) else { return nil }
        let rects = buttons.compactMap { AX.rect($0) }
        guard rects.count == 3 else { return nil }
        let matches = SystemWindow.visible().filter { $0.pid == app.processIdentifier && $0.layer == 0 && SystemWindow.close($0.bounds, frame) }
        guard matches.count == 1 else { return nil }
        // Fail closed for sheets, fullscreen windows, and inaccessible window geometry.
        if let children = AX.value(window, kAXChildrenAttribute) as? [AXUIElement],
           children.contains(where: { AX.string($0, kAXRoleAttribute) == kAXSheetRole }) { return nil }
        guard let screen = screen(for: frame), !SystemWindow.close(frame, toAX(screen.frame), tolerance: 1) else { return nil }
        return WindowTarget(pid: app.processIdentifier, window: window, id: matches[0].id, frame: frame,
                            buttons: buttons, buttonFrames: rects, name: app.localizedName ?? "Aplicativo")
    }

    func isCurrent() -> Bool {
        guard let current = WindowTarget.focused() else { return false }
        return current.pid == pid && current.id == id && AX.same(current.window, window) && SystemWindow.close(current.frame, frame)
    }
    // No AXWindowNumber or other undocumented attributes. CG matching must be unique.
    func ownsTopmostPoint(_ point: CGPoint) -> Bool {
        let own = getpid()
        guard let top = SystemWindow.visible().first(where: { $0.pid != own && $0.bounds.contains(point) && $0.layer >= 0 }) else { return false }
        return top.id == id
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

    func obstacles() -> [CGRect] {
        var obstacles: [CGRect] = [], visited = 0
        let band = CGRect(x: frame.minX, y: frame.minY, width: min(frame.width, 330), height: min(frame.height, 145))
        let interactive: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXTextFieldRole,
                                       kAXComboBoxRole, kAXPopUpButtonRole, kAXSliderRole, kAXStaticTextRole,
                                       kAXMenuButtonRole, NSAccessibility.Role.link.rawValue, kAXTabGroupRole]
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 9, visited < 350 else { return }; visited += 1
            if buttons.contains(where: { AX.same($0, element) }) { return }
            if let rect = AX.rect(element) {
                guard band.intersects(rect) else { return }
                if let role = AX.string(element, kAXRoleAttribute), interactive.contains(role) {
                    obstacles.append(rect.insetBy(dx: -2, dy: -2)); return
                }
            }
            if let children = AX.value(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { walk(child, depth: depth+1) }
            }
        }
        walk(window, depth: 0)
        return obstacles
    }
}
