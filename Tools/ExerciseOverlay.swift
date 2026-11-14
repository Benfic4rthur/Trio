import AppKit
import ApplicationServices

// End-to-end fixture-only exercise. No arbitrary application/PID/coordinate
// arguments are accepted. Every mouse event requires live AX+CG identity proof.
let fixtureID = "com.allm4.TrioFixture", trioID = "com.allm4.Trio"
let args = ProcessInfo.processInfo.arguments
func argument(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i+1) else { return nil }
    return args[i+1]
}
let action = argument("--action") ?? "inspect"
let output = argument("--output")
var report: [String: Any] = ["action": action, "generatedAt": ISO8601DateFormatter().string(from: Date()),
                            "fixtureBundleID": fixtureID, "trioBundleID": trioID]
func finish(_ status: Int32 = 0) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    if let output { try? data.write(to: URL(fileURLWithPath: output), options: .atomic) }
    print(String(data: data, encoding: .utf8)!)
    exit(status)
}
func abort(_ reason: String) -> Never { report["aborted"] = reason; finish(2) }
func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}
func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let result = value(element, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
    return (result as! AXUIElement)
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
          point.x.isFinite, point.y.isFinite, size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}
func rect(_ frame: CGRect) -> [String: CGFloat] { ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height] }
func pid(_ element: AXUIElement) -> pid_t { var result: pid_t = 0; AXUIElementGetPid(element, &result); return result }
func hit(_ point: CGPoint) -> AXUIElement? {
    var result: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &result) == .success else { return nil }
    return result
}
struct CGRow {
    let id: Int, pid: Int32, layer: Int, frame: CGRect
    var json: [String: Any] { ["id": id, "pid": pid, "layer": layer, "frame": rect(frame)] }
}
func visibleRows() -> [CGRow] {
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return rows.compactMap { row in
        guard let id = row[kCGWindowNumber as String] as? Int, let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let layer = row[kCGWindowLayer as String] as? Int,
              let dict = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: dict) else { return nil }
        return CGRow(id: id, pid: pid, layer: layer, frame: frame)
    }
}
func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX-b.minX) < 2 && abs(a.minY-b.minY) < 2 && abs(a.width-b.width) < 2 && abs(a.height-b.height) < 2
}
func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
guard ["inspect", "hover-green", "move-away", "click-green", "click-yellow", "click-red"].contains(action) else { abort("Unsupported action") }
report["accessibilityTrusted"] = AXIsProcessTrusted()
report["postEventAccess"] = CGPreflightPostEventAccess()
guard AXIsProcessTrusted() else { abort("Accessibility not already authorized; no permission requested") }
if args.contains("--activate-fixture") { settle(0.6) }
let fixtures = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID)
let trios = NSRunningApplication.runningApplications(withBundleIdentifier: trioID)
guard fixtures.count == 1, let fixture = fixtures.first, trios.count == 1, let trio = trios.first else { abort("Expected exactly one fixture and one Trio instance") }
let fixturePID = fixture.processIdentifier, trioPID = trio.processIdentifier
report["fixturePID"] = fixturePID; report["trioPID"] = trioPID
func fixtureIsFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID }
if args.contains("--activate-fixture"), !fixtureIsFront() {
    let knownFixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/fixtures/TrioFixture.app").resolvingSymlinksInPath()
    guard let appURL = fixture.bundleURL?.resolvingSymlinksInPath(), appURL == knownFixture,
          Bundle(url: appURL)?.bundleIdentifier == fixtureID else {
        abort("Fixture activation refused: bundle path is not the owned fixture build")
    }
    report["fixtureActivationRequested"] = true
    report["runningApplicationActivationAccepted"] = fixture.activate(options: [.activateAllWindows])
    settle(0.3)
    if !fixtureIsFront() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        var completed = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { activated, error in
            report["workspaceActivationCallbackBundleID"] = activated?.bundleIdentifier ?? "none"
            if let error { report["workspaceActivationError"] = error.localizedDescription }
            completed = true
        }
        let deadline = Date().addingTimeInterval(2)
        while !completed, Date() < deadline { settle(0.05) }
        settle(0.4)
    }
    report["frontmostAfterActivation"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
}
guard fixtureIsFront(), fixture.isActive else { abort("Fixture is not frontmost; no activation attempted") }
let axApp = AXUIElementCreateApplication(fixturePID)
AXUIElementSetMessagingTimeout(axApp, 0.25)
guard let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1, let window = windows.first,
      value(window, kAXRoleAttribute) as? String == kAXWindowRole,
      value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
      value(window, kAXMinimizedAttribute) as? Bool == false, let windowFrame = frame(window) else { abort("Fixture must expose one unminimized standard window") }
let nativeAttributes = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
let native = nativeAttributes.compactMap { element(window, $0) }
let nativeFrames = native.compactMap { frame($0) }
guard native.count == 3, nativeFrames.count == 3,
      native.allSatisfy({ value($0, kAXEnabledAttribute) as? Bool == true }),
      nativeFrames.allSatisfy({ windowFrame.contains($0) }) else { abort("Fixture native controls unavailable or disabled; no event posted") }
let nativeUnion = nativeFrames.dropFirst().reduce(nativeFrames[0]) { $0.union($1) }
var rows = visibleRows()
let fixtureCG = rows.filter { $0.pid == fixturePID && $0.layer == 0 && close($0.frame, windowFrame) }
guard fixtureCG.count == 1 else { abort("Fixture CG window identity is ambiguous") }
func matchingOverlays(_ candidates: [CGRow]) -> [CGRow] { candidates.filter { row in
    row.pid == trioPID && row.layer == 0 && windowFrame.contains(row.frame) && row.frame.contains(nativeUnion) &&
    row.frame.minX >= windowFrame.minX && row.frame.maxX <= nativeFrames[2].maxX+5.5 &&
    row.frame.height <= 2*(nativeUnion.midY-windowFrame.minY)+1
} }
var overlays = matchingOverlays(rows)
let overlayDeadline = Date().addingTimeInterval(1.2)
while overlays.isEmpty, fixtureIsFront(), Date() < overlayDeadline {
    settle(0.08); rows = visibleRows(); overlays = matchingOverlays(rows)
}
report["windowBefore"] = rect(windowFrame)
report["nativeControlsBefore"] = nativeFrames.map(rect)
report["trioPanelsBefore"] = rows.filter { $0.pid == trioPID }.map(\.json)
guard overlays.count == 1, let overlay = overlays.first else { abort("No uniquely verified Trio overlay in the fixture control region") }
report["windowBefore"] = rect(windowFrame)
report["nativeControlsBefore"] = nativeFrames.map(rect)
report["overlayBefore"] = overlay.json
report["trioPanelsBefore"] = rows.filter { $0.pid == trioPID }.map(\.json)
let labels = ["Fechar pelo botão original", "Minimizar janela", "Maximizar ou restaurar janela"]
var controlPoints: [Int: CGPoint] = [:]
var controlFrames: [Int: CGRect] = [:]
var hitSummaries: [String: [String: Any]] = [:]
func knownLabel(_ element: AXUIElement) -> Int? {
    guard pid(element) == trioPID, value(element, kAXRoleAttribute) as? String == kAXButtonRole else { return nil }
    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
        if let label = value(element, attribute) as? String, let index = labels.firstIndex(of: label) { return index }
    }
    return nil
}
// Query only the verified overlay strip. Read only Trio's own fixed labels.
for x in stride(from: overlay.frame.minX+2, through: overlay.frame.maxX-2, by: 2) {
    let point = CGPoint(x: x, y: nativeUnion.midY)
    if let node = hit(point) {
        var nodeReport: [String: Any] = ["pid": pid(node), "role": value(node, kAXRoleAttribute) as? String ?? "unknown"]
        if let nodeFrame = frame(node) { nodeReport["frame"] = rect(nodeFrame) }
        if pid(node) == trioPID {
            nodeReport["title"] = value(node, kAXTitleAttribute) as? String ?? "none"
            nodeReport["description"] = value(node, kAXDescriptionAttribute) as? String ?? "none"
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: nodeReport, options: .sortedKeys),
           let key = String(data: encoded, encoding: .utf8) { hitSummaries[key] = nodeReport }
    }
    if let node = hit(point), let index = knownLabel(node), let nodeFrame = frame(node),
       overlay.frame.insetBy(dx: -2, dy: -2).contains(nodeFrame) {
        let center = CGPoint(x: nodeFrame.midX, y: nativeUnion.midY)
        if let centerNode = hit(center), knownLabel(centerNode) == index { controlPoints[index] = center; controlFrames[index] = nodeFrame }
    }
}
report["stripAXHits"] = Array(hitSummaries.values)
guard controlPoints.count == 3 else { abort("All three Trio controls could not be proven by global AX hit-test and fixed labels") }
report["trioControlsBefore"] = (0..<3).map { ["index": $0, "label": labels[$0], "frame": rect(controlFrames[$0]!)] as [String: Any] }
if action != "inspect" {
    guard CGPreflightPostEventAccess() else { abort("Posting not already authorized; no permission requested") }
    let index = action == "click-red" ? 0 : action == "click-yellow" ? 1 : 2
    var point = controlPoints[index]!
    if action == "move-away" {
        point = CGPoint(x: windowFrame.maxX-70, y: windowFrame.maxY-70)
        guard let node = hit(point), pid(node) == fixturePID else { abort("Move-away point is not the disposable fixture") }
    } else {
        guard let node = hit(point), knownLabel(node) == index,
              let topNormal = visibleRows().first(where: { $0.layer == 0 && $0.frame.contains(point) }),
              topNormal.pid == trioPID, topNormal.id == overlay.id else { abort("Trio no longer owns the target control point") }
    }
    guard fixtureIsFront(), let current = frame(window), close(current, windowFrame) else { abort("Fixture changed before event posting") }
    report["eventPoint"] = ["x": point.x, "y": point.y]
    guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { abort("Cannot construct move") }
    move.flags = []; move.post(tap: .cghidEventTap)
    if action.hasPrefix("click-") {
        settle(0.06)
        guard fixtureIsFront(), let node = hit(point), knownLabel(node) == index,
              let current = frame(window), close(current, windowFrame),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { abort("Fixture/control changed after mouse movement; no click posted") }
        down.flags = []; up.flags = []
        down.setIntegerValueField(.mouseEventClickState, value: 1); up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap); settle(0.045); up.post(tap: .cghidEventTap)
        report["posted"] = "mouseMoved + physical-path leftMouseDown/leftMouseUp into Trio"
    } else { report["posted"] = "mouseMoved only; no click" }
    settle(0.65)
}
report["fixtureStillFront"] = fixtureIsFront()
report["fixtureProcessRunningAfter"] = NSRunningApplication(processIdentifier: fixturePID).map { !$0.isTerminated } ?? false
report["trioProcessRunningAfter"] = NSRunningApplication(processIdentifier: trioPID).map { !$0.isTerminated } ?? false
if let after = frame(window) { report["windowAfter"] = rect(after) }
if let minimized = value(window, kAXMinimizedAttribute) as? Bool { report["minimizedAfter"] = minimized }
if let fullScreen = value(window, "AXFullScreen") as? Bool { report["fullScreenAfter"] = fullScreen }
report["trioPanelsAfter"] = visibleRows().filter { $0.pid == trioPID }.map(\.json)
report["frontmostBundleIDAfter"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
finish()
