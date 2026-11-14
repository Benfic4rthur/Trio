import AppKit
import ApplicationServices

// Read-only probe. Deliberately omits document/window titles, text values,
// URLs, accessibility labels and process command lines. Never requests trust.
struct AXRead {
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = value(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let sizeValue = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func rect(_ frame: CGRect) -> [String: Double] {
        ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }
    static func summary(_ element: AXUIElement) -> [String: Any] {
        var result: [String: Any] = [:]
        if let role = value(element, kAXRoleAttribute) as? String { result["role"] = role }
        if let subrole = value(element, kAXSubroleAttribute) as? String { result["subrole"] = subrole }
        if let frame = frame(element) { result["frame"] = rect(frame) }
        if let enabled = value(element, kAXEnabledAttribute) as? Bool { result["enabled"] = enabled }
        if let hidden = value(element, kAXHiddenAttribute) as? Bool { result["hidden"] = hidden }
        return result
    }
    static func upperLeftElements(_ window: AXUIElement, controls: [AXUIElement]) -> [String: Any] {
        guard let windowFrame = frame(window) else { return ["elements": []] }
        let band = CGRect(x: windowFrame.minX, y: windowFrame.minY, width: min(330, windowFrame.width), height: min(145, windowFrame.height))
        var visited = 0
        var result: [[String: Any]] = []
        var hierarchy: [[String: Any]] = []
        let roles: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXTextFieldRole, kAXComboBoxRole,
                                  kAXPopUpButtonRole, kAXSliderRole, kAXStaticTextRole, kAXMenuButtonRole, kAXTabGroupRole, "AXLink"]
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 9, visited < 350 else { return }
            visited += 1
            var node = summary(element)
            node["depth"] = depth
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { node["childCount"] = children.count }
            hierarchy.append(node)
            if controls.contains(where: { CFEqual($0, element) }) { return }
            if let frame = frame(element) {
                guard band.intersects(frame) else { return }
                if let role = value(element, kAXRoleAttribute) as? String, roles.contains(role) {
                    result.append(summary(element)); return
                }
            }
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { walk(child, depth: depth + 1) }
            }
        }
        walk(window, depth: 0)
        return ["band": rect(band), "visited": visited, "truncated": visited >= 350, "elements": result, "hierarchy": hierarchy]
    }
}

let arguments = ProcessInfo.processInfo.arguments
var bundleIDs: [String] = []
var output: String?
for index in arguments.indices.dropFirst() {
    guard arguments.indices.contains(index + 1) else { continue }
    if arguments[index] == "--bundle" { bundleIDs.append(arguments[index + 1]) }
    if arguments[index] == "--output" { output = arguments[index + 1] }
}
if bundleIDs.isEmpty { bundleIDs = ["com.openai.codex", "com.microsoft.edgemac", "com.allm4.TrioFixture"] }
let apps = NSWorkspace.shared.runningApplications
let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let front = NSWorkspace.shared.frontmostApplication
var report: [String: Any] = [
    "generatedAt": ISO8601DateFormatter().string(from: Date()),
    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    "accessibilityTrusted": AXIsProcessTrusted(),
    "postEventAccess": CGPreflightPostEventAccess(),
    "frontmostBundleID": front?.bundleIdentifier ?? "unknown",
    "coordinates": "AX/CG origin top-left; points; NSScreen origin bottom-left",
    "omits": ["window/document titles", "text values", "URLs", "labels", "command lines"]
]
report["screens"] = NSScreen.screens.map { ["frame": AXRead.rect($0.frame), "visibleFrame": AXRead.rect($0.visibleFrame), "scale": $0.backingScaleFactor] as [String: Any] }
var appReports: [[String: Any]] = []
for bundleID in bundleIDs {
    let matching = apps.filter { $0.bundleIdentifier == bundleID }
    if matching.isEmpty { appReports.append(["bundleID": bundleID, "running": false]); continue }
    for app in matching {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var rawWindows: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &rawWindows)
        let windows = rawWindows as? [AXUIElement] ?? []
        let focused = AXRead.element(axApp, kAXFocusedWindowAttribute)
        var appReport: [String: Any] = ["bundleID": bundleID, "name": app.localizedName ?? bundleID, "pid": app.processIdentifier,
                                        "running": true, "active": app.isActive, "hidden": app.isHidden,
                                        "windowsAXResult": error.rawValue, "windowCount": windows.count]
        appReport["visibleCGWindows"] = visible.compactMap { item -> [String: Any]? in
            guard item[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return ["id": item[kCGWindowNumber as String] ?? -1, "layer": item[kCGWindowLayer as String] ?? -1,
                    "frame": AXRead.rect(frame)]
        }
        appReport["windows"] = windows.enumerated().map { index, window -> [String: Any] in
            var result = AXRead.summary(window)
            result["index"] = index
            result["focused"] = focused.map { CFEqual($0, window) } ?? false
            result["positionSettable"] = AXRead.isSettable(window, kAXPositionAttribute)
            result["sizeSettable"] = AXRead.isSettable(window, kAXSizeAttribute)
            for name in [kAXMinimizedAttribute, kAXMainAttribute, "AXFullScreen"] {
                if let flag = AXRead.value(window, name) as? Bool { result[name] = flag }
            }
            let attributes = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
            var controls: [AXUIElement] = []
            result["controls"] = attributes.map { attribute -> [String: Any] in
                guard let control = AXRead.element(window, attribute) else { return ["attribute": attribute, "present": false] }
                controls.append(control)
                var summary = AXRead.summary(control)
                summary["attribute"] = attribute
                summary["present"] = true
                var actions: CFArray?
                if AXUIElementCopyActionNames(control, &actions) == .success { summary["actions"] = actions as? [String] ?? [] }
                return summary
            }
            result["nearbyElements"] = AXRead.upperLeftElements(window, controls: controls)
            return result
        }
        appReports.append(appReport)
    }
}
report["applications"] = appReports
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
if let output {
    let url = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}
print(String(data: data, encoding: .utf8)!)
