import AppKit
import ApplicationServices

// Destructive actions are restricted to our disposable fixture bundle.
// This program cannot target arbitrary applications or document windows.
let expectedBundleID = "com.allm4.TrioFixture"
let arguments = ProcessInfo.processInfo.arguments
let action = arguments.count > 1 ? arguments[1] : "inspect"
let allowed = ["inspect", "axpress", "hid", "quit-fixture"]
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(2) }
guard allowed.contains(action) else { fail("Use inspect, axpress, hid or quit-fixture") }
guard AXIsProcessTrusted() else { fail("Acessibilidade ausente; nenhuma permissão foi solicitada.") }
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleID)
guard apps.count == 1, let app = apps.first else { fail("Expected exactly one disposable fixture instance, found \(apps.count).") }
let pid = app.processIdentifier
let axApp = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(axApp, 0.3)
func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
    return result
}
func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
    return (result as! AXUIElement)
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = value(element, kAXPositionAttribute), let sizeValue = value(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
func windowCount() -> Int? {
    guard let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    return windows.count
}
func rect(_ frame: CGRect) -> [String: Double] { ["x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height] }
var report: [String: Any] = ["action":action,"fixtureBundleID":expectedBundleID,"pid":pid,
                           "time":ISO8601DateFormatter().string(from:Date()),
                           "accessibilityTrusted":AXIsProcessTrusted(),"postEventAccess":CGPreflightPostEventAccess()]
report["windowsBefore"] = windowCount() ?? -1
if action == "quit-fixture" {
    report["terminateRequestAccepted"] = app.terminate()
} else {
    guard let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1, let window = windows.first,
          value(window,kAXRoleAttribute) as? String == kAXWindowRole,
          value(window,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
          value(window,kAXMinimizedAttribute) as? Bool == false,
          let button = element(window,kAXCloseButtonAttribute),
          value(button,kAXSubroleAttribute) as? String == kAXCloseButtonSubrole,
          value(button,kAXEnabledAttribute) as? Bool == true,
          let buttonFrame = frame(button), let windowFrame = frame(window),
          windowFrame.contains(buttonFrame) else { fail("Fixture window/button checks failed; no action performed.") }
    report["windowFrame"] = rect(windowFrame)
    report["buttonFrame"] = rect(buttonFrame)
    if action == "axpress" {
        report["axPressResult"] = AXUIElementPerformAction(button,kAXPressAction as CFString).rawValue
    } else if action == "hid" {
        if !app.isActive { _ = app.activate(options: []); usleep(250_000) }
        guard CGPreflightPostEventAccess(), app.isActive else { fail("Fixture must be active, posting must already be authorized.") }
        let point = CGPoint(x:buttonFrame.midX,y:buttonFrame.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,
              let hit, CFEqual(hit,button) else { fail("Original fixture close button is not exposed at this point; no click posted.") }
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let top = rows.first { row in
            guard row[kCGWindowLayer as String] as? Int == 0,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation:dict) else { return false }
            return bounds.contains(point)
        }
        guard top?[kCGWindowOwnerPID as String] as? Int32 == pid else { fail("Fixture is not the topmost window; no click posted.") }
        let previousPointer = CGEvent(source:nil)?.location
        guard let down = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
              let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else { fail("Cannot construct events") }
        down.setIntegerValueField(.mouseEventClickState,value:1)
        up.setIntegerValueField(.mouseEventClickState,value:1)
        down.post(tap:.cghidEventTap)
        usleep(60_000)
        up.post(tap:.cghidEventTap)
        report["postedAt"] = ["x":point.x,"y":point.y]
        report["postLocation"] = "cghidEventTap"
        usleep(150_000)
        if let previousPointer, let current = CGEvent(source:nil)?.location,
           hypot(current.x-point.x,current.y-point.y) < 3 {
            CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:previousPointer,mouseButton:.left)?.post(tap:.cghidEventTap)
            report["pointerRestored"] = true
        }
    }
}
if action != "inspect" { usleep(700_000) }
let after = NSRunningApplication(processIdentifier:pid)
report["processRunningAfter"] = after.map { !$0.isTerminated } ?? false
report["windowsAfter"] = windowCount() ?? -1
let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
print(String(data:data,encoding:.utf8)!)
