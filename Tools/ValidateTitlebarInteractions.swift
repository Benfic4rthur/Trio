import AppKit
import ApplicationServices

// Fixture-only regression test: stationary title-bar presses must not hide Trio.
// No arbitrary process, URL or point can be passed on the command line.
@main struct ValidateTitlebarInteractions {
    @MainActor static func main() throws {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        let baseline = CommandLine.arguments.contains("--baseline")
        let fixtureID = "com.allm4.TrioFixture.Alignment"
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/fixtures/TrioAlignmentFixture.app").resolvingSymlinksInPath()
        guard Bundle(url: url)?.bundleIdentifier == fixtureID, AXIsProcessTrusted(), CGPreflightPostEventAccess() else { fatalError("Owned fixture or existing permissions unavailable") }
        func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        for old in NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID) {
            guard old.bundleURL?.resolvingSymlinksInPath() == url else { fatalError("Unexpected fixture path") }
            old.terminate(); for _ in 0..<20 { if old.isTerminated { break }; wait(0.1) }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.addsToRecentItems = false
        var fixture: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in fixture = app }
        for _ in 0..<40 { if fixture != nil { break }; wait(0.1) }
        guard let fixture, fixture.bundleURL?.resolvingSymlinksInPath() == url,
              let trio = NSRunningApplication.runningApplications(withBundleIdentifier: "com.allm4.Trio").first else { fatalError("Test processes unavailable") }
        defer { fixture.terminate() }
        wait(1.1)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != fixture.processIdentifier { _ = fixture.activate(options: [.activateAllWindows]); wait(0.5) }
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? { var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(element,name as CFString,&v) == .success else { return nil }; return v }
        func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? { guard let v = value(parent,name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }; return v as! AXUIElement }
        func frame(_ node: AXUIElement) -> CGRect? {
            guard let p = value(node,kAXPositionAttribute),let s = value(node,kAXSizeAttribute), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero,size = CGSize.zero
            guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }; return CGRect(origin:point,size:size)
        }
        struct Window { let id: UInt32; let pid: Int32; let layer: Int; let bounds: CGRect }
        func visible() -> [Window] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []).compactMap { row in
                guard let id = row[kCGWindowNumber as String] as? UInt32,let pid = row[kCGWindowOwnerPID as String] as? Int32,let layer = row[kCGWindowLayer as String] as? Int,let b = row[kCGWindowBounds as String] as? NSDictionary,let bounds = CGRect(dictionaryRepresentation:b) else { return nil }; return Window(id:id,pid:pid,layer:layer,bounds:bounds)
            }
        }
        func panelVisible() -> Bool { visible().contains { $0.pid == trio.processIdentifier && $0.layer == 3 } }
        let axApp = AXUIElementCreateApplication(fixture.processIdentifier)
        guard let window = element(axApp,kAXFocusedWindowAttribute),let initial = frame(window),
              let close = element(window,kAXCloseButtonAttribute),let button = frame(close),panelVisible() else { fatalError("Fixture/Trio geometry not ready") }
        let candidates = visible().filter { $0.pid == fixture.processIdentifier && $0.layer == 0 && abs($0.bounds.minX-initial.minX)<1 && abs($0.bounds.minY-initial.minY)<1 && abs($0.bounds.width-initial.width)<1 && abs($0.bounds.height-initial.height)<1 }
        guard candidates.count == 1 else { fatalError("Ambiguous fixture identity") }
        let id = candidates[0].id
        var clicks: [[String:Any]] = []
        var totalMissing = 0
        func post(_ type: CGEventType, _ point: CGPoint) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
                  visible().first(where: { $0.layer == 0 && $0.bounds.contains(point) })?.id == id else { fatalError("Fixture point is no longer topmost; no event posted") }
            let e = CGEvent(mouseEventSource: CGEventSource(stateID:.hidSystemState),mouseType:type,mouseCursorPosition:point,mouseButton:.left)!
            e.setIntegerValueField(.mouseEventClickState,value:1)
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(id))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(id))
            e.post(tap:.cghidEventTap)
        }
        for fraction in [0.60,0.76,0.92] {
            let point = CGPoint(x:initial.minX+initial.width*fraction,y:button.midY)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,let hit else { fatalError("Fixture title hit unavailable") }
            var hitPID: pid_t = 0; AXUIElementGetPid(hit,&hitPID)
            guard hitPID == fixture.processIdentifier else { fatalError("Title does not belong to fixture") }
            let role = value(hit,kAXRoleAttribute) as? String ?? "unknown"
            guard [kAXWindowRole,kAXGroupRole,kAXToolbarRole,kAXStaticTextRole].contains(role) else { fatalError("Refused interactive toolbar target") }
            var missing = 0
            post(.leftMouseDown,point)
            for _ in 0..<12 { wait(0.01); if !panelVisible() { missing += 1 } }
            post(.leftMouseUp,point)
            for _ in 0..<12 { wait(0.01); if !panelVisible() { missing += 1 } }
            let unchanged = frame(window).map { abs($0.minX-initial.minX)<0.1 && abs($0.minY-initial.minY)<0.1 && abs($0.width-initial.width)<0.1 && abs($0.height-initial.height)<0.1 } ?? false
            clicks.append(["fraction":fraction,"hitRole":role,"missingSamples":missing,"windowUnchanged":unchanged])
            totalMissing += missing
            wait(0.2)
        }
        var report: [String:Any] = ["baseline":baseline,"fixturePID":fixture.processIdentifier,"trioPID":trio.processIdentifier,"titleClicks":clicks,"totalMissingSamples":totalMissing]
        var passed = clicks.allSatisfy { $0["windowUnchanged"] as? Bool == true } && (baseline ? totalMissing>0 : totalMissing==0)
        if !baseline {
            // Establish that a held press remains visible, then a real drag
            // hides the panel and release recovers it at the final geometry.
            let start = CGPoint(x:initial.minX+initial.width*0.76,y:button.midY)
            post(.leftMouseDown,start); wait(0.08)
            let heldVisible = panelVisible()
            var hiddenOnDrag = false
            for step in 1...6 {
                let point = CGPoint(x:start.x+CGFloat(step)*8,y:start.y+CGFloat(step)*5)
                post(.leftMouseDragged,point); wait(0.025)
                if !panelVisible() { hiddenOnDrag = true }
            }
            post(.leftMouseUp,CGPoint(x:start.x+48,y:start.y+30))
            wait(0.35)
            let returned = panelVisible()
            let moved = frame(window).map { abs($0.minX-initial.minX)>1 || abs($0.minY-initial.minY)>1 } ?? false
            report["heldPressVisible"] = heldVisible;report["hiddenDuringDrag"] = hiddenOnDrag;report["returnedAfterDrag"] = returned;report["windowActuallyMoved"] = moved
            passed = passed && heldVisible && hiddenOnDrag && returned && moved
        }
        report["passed"] = passed
        let file = baseline ? "build/titlebar-baseline.json" : "build/titlebar-fixed.json"
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:file))
        print("\(passed ? "PASS" : "FAIL"): \(file)")
        if !passed { exit(2) }
    }
}
