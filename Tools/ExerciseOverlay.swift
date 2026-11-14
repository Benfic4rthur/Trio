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
    let order: Int, id: Int, pid: Int32, layer: Int, frame: CGRect
    var json: [String: Any] { ["order": order, "id": id, "pid": pid, "layer": layer, "frame": rect(frame)] }
}
func visibleRows() -> [CGRow] {
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return rows.enumerated().compactMap { order, row in
        guard let id = row[kCGWindowNumber as String] as? Int, let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let layer = row[kCGWindowLayer as String] as? Int,
              let dict = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: dict) else { return nil }
        return CGRow(order: order, id: id, pid: pid, layer: layer, frame: frame)
    }
}
func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX-b.minX) < 2 && abs(a.minY-b.minY) < 2 && abs(a.width-b.width) < 2 && abs(a.height-b.height) < 2
}
func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
guard ["inspect", "hover-green", "hover-red", "hover-popup", "move-away", "content-clicks", "drag-window", "resize-window", "snap-left", "snap-right", "center", "click-green", "click-yellow", "click-red"].contains(action) else { abort("Unsupported action") }
report["accessibilityTrusted"] = AXIsProcessTrusted()
report["postEventAccess"] = CGPreflightPostEventAccess()
guard AXIsProcessTrusted() else { abort("Accessibility not already authorized; no permission requested") }
if args.contains("--activate-fixture") { settle(args.contains("--arrange-fixture-pair") ? 1.2 : 0.6) }
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
guard let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement], (1...2).contains(windows.count),
      windows.allSatisfy({ pid($0) == fixturePID && value($0,kAXRoleAttribute) as? String == kAXWindowRole && (value($0,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole || value($0,kAXMinimizedAttribute) as? Bool == true) }) else { abort("Fixture must expose one or two owned standard windows") }
report["fixtureWindowCount"] = windows.count
if args.contains("--restore-minimized-fixture") {
    for owned in windows where value(owned,kAXMinimizedAttribute) as? Bool == true {
        guard AXUIElementSetAttributeValue(owned,kAXMinimizedAttribute as CFString,kCFBooleanFalse) == .success else { abort("Cannot restore minimized owned fixture for test setup") }
    }
    _ = fixture.activate(options:[.activateAllWindows])
    settle(0.45)
}
if args.contains("--arrange-fixture-pair") {
    guard windows.count == 2 else { abort("Two owned fixture windows required for pair setup") }
    for (index,owned) in windows.enumerated() {
        var point = CGPoint(x: 180+CGFloat(index)*260, y: 260+CGFloat(index)*240)
        var size = CGSize(width: 900-CGFloat(index)*40, height: 620)
        guard let p = AXValueCreate(.cgPoint,&point), let s = AXValueCreate(.cgSize,&size),
              AXUIElementSetAttributeValue(owned,kAXPositionAttribute as CFString,p) == .success,
              AXUIElementSetAttributeValue(owned,kAXSizeAttribute as CFString,s) == .success else { abort("Could not set up distinct owned fixture window geometries") }
    }
    settle(0.45)
}
if args.contains("--small-fixture") {
    guard let owned = element(axApp,kAXFocusedWindowAttribute), windows.contains(where:{CFEqual($0,owned)}), value(owned,kAXMinimizedAttribute) as? Bool == false else { abort("No owned fixture for small setup") }
    var point = CGPoint(x:320,y:260), size = CGSize(width:900,height:620)
    guard let p = AXValueCreate(.cgPoint,&point), let v = AXValueCreate(.cgSize,&size),
          AXUIElementSetAttributeValue(owned,kAXPositionAttribute as CFString,p) == .success,
          AXUIElementSetAttributeValue(owned,kAXSizeAttribute as CFString,v) == .success else { abort("Cannot prepare small owned fixture") }
    settle(0.35)
}
if args.contains("--focus-other-fixture") {
    guard let focused = element(axApp,kAXFocusedWindowAttribute), let other = windows.first(where:{ !CFEqual($0,focused) }),
          AXUIElementPerformAction(other,kAXRaiseAction as CFString) == .success else { abort("Could not raise second owned fixture window") }
    settle(0.45)
}
guard let window = element(axApp,kAXFocusedWindowAttribute), windows.contains(where:{CFEqual($0,window)}),
      value(window,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
      value(window,kAXMinimizedAttribute) as? Bool == false, let windowFrame = frame(window) else { abort("Fixture must have one owned unminimized focused standard window") }
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
    row.pid == trioPID && row.layer == 3 && windowFrame.contains(row.frame) && row.frame.contains(nativeUnion) &&
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
report["overlayAboveFixtureBefore"] = overlay.layer == 3 && overlay.order < fixtureCG[0].order
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
report["reduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
func postMove(_ point: CGPoint) {
    guard CGWarpMouseCursorPosition(point) == .success else { abort("Cannot align real pointer with verified fixture/Trio event point") }
    guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { abort("Cannot construct move") }
    event.flags = []
    if let owned = visibleRows().first(where: { ($0.layer == 0 || $0.layer == 3) && $0.frame.contains(point) }), [fixturePID,trioPID].contains(owned.pid) {
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(owned.id))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(owned.id))
    }
    event.post(tap: .cghidEventTap)
}
func postClick(_ point: CGPoint) {
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { abort("Cannot construct click") }
    down.flags = []; up.flags = []
    if let owned = visibleRows().first(where: { ($0.layer == 0 || $0.layer == 3) && $0.frame.contains(point) }), [fixturePID,trioPID].contains(owned.pid) {
        for event in [down,up] {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(owned.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(owned.id))
        }
        report["postedClickWindowUnderPointer"] = owned.id
    }
    down.setIntegerValueField(.mouseEventClickState, value: 1); up.setIntegerValueField(.mouseEventClickState, value: 1)
    down.post(tap: .cghidEventTap); settle(0.045); up.post(tap: .cghidEventTap)
}
func sampleWindowAnimation() {
let began = ProcessInfo.processInfo.systemUptime
var samples: [[String: Any]] = []
var distinct: Set<String> = [], earlyDistinct: Set<String> = []
repeat {
    let t = ProcessInfo.processInfo.systemUptime-began
    if let current = frame(window) {
        var sample: [String: Any] = ["t":t,"frame":rect(current)]
        let cg = visibleRows()
        if let owned = cg.first(where: { $0.id == fixtureCG[0].id }) {
            sample["cgWindow"] = rect(owned.frame)
            if let light = cg.first(where: { $0.id == overlay.id }) {
                let dx = light.frame.minX-owned.frame.minX-(overlay.frame.minX-fixtureCG[0].frame.minX)
                let dy = light.frame.minY-owned.frame.minY-(overlay.frame.minY-fixtureCG[0].frame.minY)
                sample["panelVisible"] = true; sample["panel"] = light.json
                sample["anchorErrorX"] = dx; sample["anchorErrorY"] = dy
                sample["aligned"] = abs(dx)<=2 && abs(dy)<=2
            } else { sample["panelVisible"] = false }
        }
        samples.append(sample)
        let key = [current.minX,current.minY,current.width,current.height].map { String(format:"%.1f",Double($0)) }.joined(separator:",")
        distinct.insert(key)
        if t <= 0.3 { earlyDistinct.insert(key) }
    }
    settle(0.01)
} while ProcessInfo.processInfo.systemUptime-began < 0.45
report["animationSamples"] = samples
report["animationVisibleMisalignedSamples"] = samples.filter { $0["panelVisible"] as? Bool == true && $0["aligned"] as? Bool != true }.count
report["animationHiddenSamples"] = samples.filter { $0["panelVisible"] as? Bool != true }.count
report["distinctGeometryCount"] = distinct.count
report["distinctGeometryFirst300ms"] = earlyDistinct.count
settle(0.25)
}
if ["snap-left","snap-right","center"].contains(action) {
    guard CGPreflightPostEventAccess() else { abort("Posting not authorized") }
    let green = controlPoints[2]!
    guard fixtureIsFront(), let current = frame(window), close(current,windowFrame), let node = hit(green), knownLabel(node)==2 else { abort("Cannot safely hover own green control before arranging") }
    postMove(green); settle(0.38)
    guard let menu = visibleRows().first(where: { $0.pid == trioPID && $0.layer == 3 && $0.id != overlay.id && abs($0.frame.width-200)<2 && abs($0.frame.height-160)<2 }) else { abort("Own arrangement panel did not open") }
    let tag = action == "snap-left" ? 1 : action == "snap-right" ? 2 : 3
    let expected = ["Maximizar / restaurar","Metade esquerda","Metade direita","Centralizar"][tag]
    let point = CGPoint(x:menu.frame.midX,y:menu.frame.minY+20+CGFloat(tag)*29)
    guard let row = hit(point), pid(row)==trioPID, value(row,kAXRoleAttribute) as? String == kAXButtonRole,
          [kAXTitleAttribute,kAXDescriptionAttribute].contains(where: { value(row,$0) as? String == expected }),
          visibleRows().first(where: { ($0.layer==0 || $0.layer==3) && $0.frame.contains(point) })?.id == menu.id,
          fixtureIsFront(), let current = frame(window), close(current,windowFrame) else { abort("Own arrangement row identity could not be proven") }
    postMove(point); settle(0.04)
    report["arrangementRow"] = expected
    let result = AXUIElementPerformAction(row,kAXPressAction as CFString)
    report["ownMenuAXPressResult"] = result.rawValue
    guard result == .success else { abort("Own menu row rejected AXPress") }
    report["posted"] = "Hover own green, verify floating own popup + row, AXPress only own Trio menu row"
    sampleWindowAnimation()
} else if action == "drag-window" || action == "resize-window" {
    guard CGPreflightPostEventAccess() else { abort("Posting not authorized") }
    let startPoint = action == "drag-window"
        ? CGPoint(x: windowFrame.maxX-120, y: nativeUnion.midY)
        : CGPoint(x: windowFrame.maxX-2, y: windowFrame.maxY-2)
    guard let node = hit(startPoint), pid(node) == fixturePID,
          visibleRows().first(where: { ($0.layer == 0 || $0.layer == 3) && $0.frame.contains(startPoint) })?.id == fixtureCG[0].id,
          fixtureIsFront() else { abort("Motion start is not owned fixture title bar/resize edge") }
    let anchorX = overlay.frame.minX-fixtureCG[0].frame.minX
    let anchorY = overlay.frame.minY-fixtureCG[0].frame.minY
    var samples: [[String: Any]] = []
    let began = ProcessInfo.processInfo.systemUptime
    func motionSnapshot(_ phase: String) {
        let all = visibleRows()
        guard let current = all.first(where: { $0.id == fixtureCG[0].id }) else { return }
        let light = all.first { $0.id == overlay.id }
        var sample: [String: Any] = ["t":ProcessInfo.processInfo.systemUptime-began,"phase":phase,"window":rect(current.frame),"panelVisible":light != nil]
        if let light {
            let dx = light.frame.minX-current.frame.minX-anchorX, dy = light.frame.minY-current.frame.minY-anchorY
            sample["panel"] = light.json; sample["anchorErrorX"] = dx; sample["anchorErrorY"] = dy
            sample["aligned"] = abs(dx)<=2 && abs(dy)<=2
            sample["above"] = light.layer == 3 && light.order < current.order
        }
        samples.append(sample)
    }
    func motionEvent(_ type: CGEventType, _ point: CGPoint, dx: Int64 = 0, dy: Int64 = 0) {
        guard let event = CGEvent(mouseEventSource:CGEventSource(stateID:.hidSystemState),mouseType:type,mouseCursorPosition:point,mouseButton:.left) else { abort("Cannot create owned motion event") }
        event.flags = []; event.setIntegerValueField(.mouseEventClickState,value:1)
        event.setIntegerValueField(.mouseEventDeltaX,value:dx); event.setIntegerValueField(.mouseEventDeltaY,value:dy)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(fixtureCG[0].id))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(fixtureCG[0].id))
        if type == .leftMouseDown {
            report["postedMotionDownWindowUnderPointer"] = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            report["postedMotionDownWindowThatCanHandle"] = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        }
        event.post(tap:.cghidEventTap)
    }
    postMove(startPoint); settle(0.04)
    guard fixtureIsFront(), let current = frame(window), close(current,windowFrame), let node = hit(startPoint), pid(node)==fixturePID else { abort("Fixture changed before owned drag") }
    motionSnapshot("before")
    motionEvent(.leftMouseDown,startPoint); settle(0.025)
    let delta = action == "drag-window" ? CGPoint(x:180,y:100) : CGPoint(x:160,y:100)
    for step in 1...10 {
        let point = CGPoint(x:startPoint.x+delta.x*CGFloat(step)/10,y:startPoint.y+delta.y*CGFloat(step)/10)
        _ = CGWarpMouseCursorPosition(point)
        motionEvent(.leftMouseDragged,point,dx:Int64(delta.x/10),dy:Int64(delta.y/10))
        settle(0.02); motionSnapshot("drag-\(step)")
    }
    let end = CGPoint(x:startPoint.x+delta.x,y:startPoint.y+delta.y)
    settle(0.12); motionSnapshot("held-120ms")
    motionEvent(.leftMouseUp,end)
    settle(0.07); motionSnapshot("quiet-70ms")
    settle(0.08); motionSnapshot("quiet-150ms")
    settle(0.15); motionSnapshot("quiet-300ms")
    report["posted"] = "Owned fixture mouseDown + 10 mouseDragged steps + mouseUp"
    report["motionSamples"] = samples
    report["anchorOffset"] = ["x":anchorX,"y":anchorY]
    let visible = samples.filter { $0["panelVisible"] as? Bool == true }
    report["misalignedVisibleSamples"] = visible.filter { $0["aligned"] as? Bool != true }.count
    report["hiddenSamples"] = samples.filter { $0["panelVisible"] as? Bool != true }.count
    if let after = frame(window) { report["motionOccurred"] = !close(windowFrame,after) }
} else if action == "content-clicks" {
    guard CGPreflightPostEventAccess() else { abort("Posting not authorized") }
    var snapshots: [[String: Any]] = []
    let began = ProcessInfo.processInfo.systemUptime
    var raiseResults: [Int] = []
    for fraction in [0.65,0.72,0.79] {
        _ = fixture.activate(options: [.activateAllWindows])
        let raise = AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        raiseResults.append(Int(raise.rawValue))
        guard raise == .success else { abort("Owned fixture AXRaise failed") }
        settle(0.06)
        let point = CGPoint(x: windowFrame.minX+windowFrame.width*fraction, y: windowFrame.minY+windowFrame.height*0.7)
        guard fixtureIsFront(), let current = frame(window), close(current, windowFrame),
              let node = hit(point), pid(node) == fixturePID,
              visibleRows().first(where: { ($0.layer == 0 || $0.layer == 3) && $0.frame.contains(point) })?.id == fixtureCG[0].id else { abort("Content click is not on unchanged disposable fixture") }
        postMove(point); postClick(point)
        let until = ProcessInfo.processInfo.systemUptime+0.2
        repeat {
            let snapshot = visibleRows()
            let own = snapshot.filter { $0.pid == trioPID }
            let light = own.first { $0.id == overlay.id }
            let fixtureRow = snapshot.first { $0.id == fixtureCG[0].id }
            let above = light.map { l in fixtureRow.map { f in l.layer == 3 && l.order < f.order } ?? false } ?? false
            snapshots.append(["t": ProcessInfo.processInfo.systemUptime-began, "overlayPresent": light != nil, "overlayAboveFixture": above, "trioPanels": own.map(\.json), "fixtureOrder":fixtureRow?.order ?? -1])
            settle(0.015)
        } while ProcessInfo.processInfo.systemUptime < until
    }
    report["contentClickCount"] = 3
    report["fixtureRaiseResults"] = raiseResults
    report["overlayAboveFixtureThroughoutContentClicks"] = snapshots.allSatisfy { $0["overlayAboveFixture"] as? Bool == true }
    report["contentClickSamples"] = snapshots
    report["overlayPresentThroughoutContentClicks"] = snapshots.allSatisfy { $0["overlayPresent"] as? Bool == true }
    report["posted"] = "Three physical-path clicks only into verified fixture content"
} else if action != "inspect" {
    guard CGPreflightPostEventAccess() else { abort("Posting not already authorized; no permission requested") }
    let index = action == "click-red" || action == "hover-red" ? 0 : action == "click-yellow" ? 1 : 2
    var point = controlPoints[index]!
    var expectedPanel = overlay.id
    if action == "move-away" {
        point = CGPoint(x: windowFrame.maxX-70, y: windowFrame.maxY-70)
        guard let node = hit(point), pid(node) == fixturePID else { abort("Move-away point is not the disposable fixture") }
    } else if action == "hover-popup" {
        guard let menu = visibleRows().first(where: { $0.pid == trioPID && $0.layer == 3 && $0.id != overlay.id && abs($0.frame.width-200) < 2 && abs($0.frame.height-160) < 2 }) else { abort("No own nonactivating arrangement panel visible") }
        point = CGPoint(x: menu.frame.midX, y: menu.frame.minY+20)
        let menuLabels = ["Maximizar / restaurar","Metade esquerda","Metade direita","Centralizar","Abrir Trio"]
        guard let node = hit(point), pid(node) == trioPID, value(node,kAXRoleAttribute) as? String == kAXButtonRole,
              [kAXTitleAttribute,kAXDescriptionAttribute].contains(where: { attribute in
                  (value(node,attribute) as? String).map { menuLabels.contains($0) } ?? false
              }) else { abort("Popup point is not a verified own menu button") }
        expectedPanel = menu.id
    } else {
        guard let node = hit(point), knownLabel(node) == index,
              let topNormal = visibleRows().first(where: { ($0.layer == 0 || $0.layer == 3) && $0.frame.contains(point) }),
              topNormal.pid == trioPID, topNormal.id == expectedPanel else { abort("Trio no longer owns the target control point") }
    }
    guard fixtureIsFront(), let current = frame(window), close(current, windowFrame) else { abort("Fixture changed before event posting") }
    report["eventPoint"] = ["x": point.x, "y": point.y]
    postMove(point)
    if action.hasPrefix("click-") {
        settle(0.06)
        guard fixtureIsFront(), let node = hit(point), knownLabel(node) == index,
              let current = frame(window), close(current, windowFrame) else { abort("Fixture/control changed after movement; no click posted") }
        postClick(point)
        report["posted"] = "mouseMoved + physical-path leftMouseDown/leftMouseUp into Trio"
        if action == "click-green" {
            sampleWindowAnimation()
        } else { settle(0.65) }
    } else { report["posted"] = "mouseMoved only; no click"; settle(0.65) }
}
report["fixtureStillFront"] = fixtureIsFront()
report["fixtureProcessRunningAfter"] = NSRunningApplication(processIdentifier: fixturePID).map { !$0.isTerminated } ?? false
report["trioProcessRunningAfter"] = NSRunningApplication(processIdentifier: trioPID).map { !$0.isTerminated } ?? false
if let after = frame(window) { report["windowAfter"] = rect(after) }
if let minimized = value(window, kAXMinimizedAttribute) as? Bool { report["minimizedAfter"] = minimized }
if let fullScreen = value(window, "AXFullScreen") as? Bool { report["fullScreenAfter"] = fullScreen }
report["trioPanelsAfter"] = visibleRows().filter { $0.pid == trioPID }.map(\.json)
if let pointer = CGEvent(source:nil)?.location { report["pointerAfter"] = ["x":pointer.x,"y":pointer.y] }
report["frontmostBundleIDAfter"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
finish()
