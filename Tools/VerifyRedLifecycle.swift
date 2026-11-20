import AppKit
import ApplicationServices

// A single, bounded, disposable-fixture exercise. Never launches or activates
// an application, posts HID events, or presses a foreign app's original button.
// The caller must already have launched the owned five-window fixture and left
// it in the foreground. Losing that foreground aborts subsequent actions.
@main @MainActor struct VerifyRedLifecycle {
    static func main() { RedLifecycleVerification().run() }
}

@MainActor private final class RedLifecycleVerification {
    private let fixtureID = "com.allm4.TrioFixture"
    private let trioID = "com.allm4.Trio"
    private let prefix = "trio-fixture-red-lifecycle-"
    private let labels = ["Fechar janela", "Minimizar janela", "Maximizar ou restaurar janela"]
    private let arguments = ProcessInfo.processInfo.arguments
    private var fixture: NSRunningApplication!
    private var trio: NSRunningApplication!
    private var logURL: URL!
    private var outputURL: URL?
    private var axApp: AXUIElement!
    private var logWindowIDs: [Int: Int] = [:]
    private var initialLaunchTime = 0.0
    private var report: [String: Any] = ["test": "five-window-red-lifecycle", "HIDPosted": false,
                                       "applicationsLaunchedOrActivated": false]
    private var steps: [[String: Any]] = []

    private struct Row {
        let id: Int, pid: pid_t, layer: Int, order: Int
        let frame: CGRect
    }

    func run() {
        report["generatedAt"] = ISO8601DateFormatter().string(from: Date())
        guard let log = argument("--fixture-log"), let output = argument("--output"),
              log.hasPrefix("/"), output.hasPrefix("/") else {
            stop("Use --fixture-log ABSOLUTE.jsonl --output ABSOLUTE.json; no action performed")
        }
        logURL = URL(fileURLWithPath: log); outputURL = URL(fileURLWithPath: output)
        guard AXIsProcessTrusted() else { stop("Accessibility is not already authorized; no permission requested") }
        let fixtures = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID)
        let trios = NSRunningApplication.runningApplications(withBundleIdentifier: trioID)
        let ownedFixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/fixtures/TrioFixture.app").resolvingSymlinksInPath()
        guard fixtures.count == 1, trios.count == 1,
              fixtures[0].bundleURL?.resolvingSymlinksInPath() == ownedFixture,
              trios[0].bundleURL?.resolvingSymlinksInPath().path == "/Applications/Trio.app" else {
            stop("Expected exactly one owned build/fixtures/TrioFixture.app and one installed Trio; no action performed")
        }
        fixture = fixtures[0]; trio = trios[0]
        report["fixturePID"] = fixture.processIdentifier; report["trioPID"] = trio.processIdentifier
        if let info = trio.bundleURL.flatMap({ Bundle(url: $0)?.infoDictionary }) {
            report["trioVersion"] = info["CFBundleShortVersionString"]
            report["trioBuild"] = info["CFBundleVersion"]
        }
        requireForeground()
        axApp = AXUIElementCreateApplication(fixture.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        let ready = Date().addingTimeInterval(4)
        while Date() < ready {
            requireForeground()
            let entries = fixtureEvents()
            if let launched = entries.last(where: { $0["event"] as? String == "launched" && $0["redLifecycleTest"] as? Bool == true }) {
                initialLaunchTime = launched["time"] as? Double ?? 0
                for entry in entries where entry["event"] as? String == "windowCreated" {
                    if let index = entry["fixtureIndex"] as? Int, let id = entry["window"] as? Int { logWindowIDs[index] = id }
                }
                if logWindowIDs.count == 5, let windows = ownedWindows(), windows.count == 5,
                   let minimized = windows[4], flag(minimized, kAXMinimizedAttribute) { break }
            }
            settle(0.05)
        }
        guard initialLaunchTime > 0, Set(logWindowIDs.keys) == Set(0..<5),
              Set(logWindowIDs.values).count == 5, let initialWindows = ownedWindows(),
              Set(initialWindows.keys) == Set(0..<5), flag(initialWindows[4]!, kAXMinimizedAttribute),
              initialWindows.filter({ flag($0.value, kAXMinimizedAttribute) }).count == 1,
              flag(initialWindows[0]!, kAXMainAttribute) else {
            stop("Five fresh lifecycle windows, including initially minimized index 4, were not proven")
        }
        report["initialWindowIDs"] = Dictionary(uniqueKeysWithValues: logWindowIDs.map { (String($0.key), $0.value) })
        report["initiallyMinimizedIndex"] = 4
        report["initialPrincipalIndex"] = 0
        report["initialPrincipalAXMain"] = true
        // Close the principal and close-only windows while another is minimized.
        // Restore that owned window while the fixture is still foreground, so
        // the test never needs to reactivate an app after an OS focus change.
        let order = [0, 2, 4, 1, 3]
        var remaining = Set(0..<5)
        for index in order {
            requireForeground()
            guard let before = ownedWindows(), Set(before.keys) == remaining,
                  let target = before[index], let expectedID = logWindowIDs[index] else {
                stop("Owned fixture window set changed before a close")
            }
            if flag(target, kAXMinimizedAttribute) {
                guard index == 4,
                      AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                    stop("Could not restore the single owned minimized fixture window")
                }
                settle(0.35); requireForeground()
            }
            guard AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success else { stop("Cannot raise owned fixture window") }
            settle(0.3); requireForeground()
            let deadline = Date().addingTimeInterval(2)
            var verified: (AXUIElement, Row, [Int])?
            while Date() < deadline {
                requireForeground()
                verified = verifiedRed(target: target, expectedCGID: expectedID, expectedSlots: index == 2 ? [0] : [0, 1, 2])
                if verified != nil { break }
                settle(0.05)
            }
            guard let (red, overlay, slots) = verified else { stop("Focused fixture identity or Trio overlay accessibility could not be proven") }
            requireForeground()
            guard let focused = element(axApp, kAXFocusedWindowAttribute), CFEqual(focused, target),
                  let current = ownedWindows(), Set(current.keys) == remaining,
                  let finalProof = verifiedRed(target: target, expectedCGID: expectedID, expectedSlots: slots),
                  finalProof.1.id == overlay.id, CFEqual(finalProof.0, red) else {
                stop("Fixture or Trio identity changed immediately before AXPress")
            }
            let press = AXUIElementPerformAction(red, kAXPressAction as CFString)
            guard press == .success else { stop("AXPress was refused by the verified Trio red control") }
            remaining.remove(index)
            let closeDeadline = Date().addingTimeInterval(remaining.isEmpty && arguments.contains("--expect-force") ? 9 : 3)
            while Date() < closeDeadline {
                if !fixtureRunning() { break }
                if !remaining.isEmpty, let after = ownedWindows(), Set(after.keys) == remaining { break }
                settle(0.04)
            }
            let running = fixtureRunning()
            var step: [String: Any] = ["fixtureIndex": index, "targetCGWindowID": expectedID,
                                      "trioOverlayCGWindowID": overlay.id, "controlIndices": slots,
                                      "AXPressResult": press.rawValue, "fixtureRunningAfter": running,
                                      "expectedRemainingCount": remaining.count]
            if !remaining.isEmpty {
                guard running, let after = ownedWindows(), Set(after.keys) == remaining else {
                    steps.append(step); stop("An intermediate red closed the wrong window or ended the fixture prematurely")
                }
                step["actualRemainingCount"] = after.count
            } else {
                guard !running else { steps.append(step); stop("The last red closed the window but did not terminate the fixture") }
                step["actualRemainingCount"] = 0
            }
            steps.append(step)
            let expectedClosed = Array(order.prefix(steps.count)).compactMap { logWindowIDs[$0] }
            let eventDeadline = Date().addingTimeInterval(0.6)
            while Date() < eventDeadline, closedIDs() != expectedClosed { settle(0.03) }
            guard closedIDs() == expectedClosed else { stop("Fixture close log does not match the exact target IDs in order") }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: trioID)
                .contains(where: { $0.processIdentifier == trio.processIdentifier && !$0.isTerminated }) else { stop("Trio unexpectedly stopped") }
        }
        let terminalEvents = fixtureEvents().filter { ($0["time"] as? Double ?? 0) >= initialLaunchTime }
        guard terminalEvents.contains(where: { $0["event"] as? String == "applicationShouldTerminate" }),
              terminalEvents.contains(where: { $0["event"] as? String == "applicationWillTerminate" }) == !arguments.contains("--expect-force") else {
            stop("Fixture exited without the expected graceful-termination events")
        }
        report["fixtureEvents"] = terminalEvents.filter {
            ["windowDidMiniaturize", "windowDidDeminiaturize", "windowWillClose", "applicationShouldTerminate", "applicationWillTerminate"].contains($0["event"] as? String ?? "")
        }.map { event in event.filter { ["event", "fixtureIndex", "pid", "time", "window"].contains($0.key) } }
        report["terminationMode"] = arguments.contains("--expect-force") ? "forced-after-refusal" : "graceful"
        report["passed"] = true; finish(0)
    }

    private func verifiedRed(target: AXUIElement, expectedCGID: Int, expectedSlots: [Int]) -> (AXUIElement, Row, [Int])? {
        guard let focused = element(axApp, kAXFocusedWindowAttribute), CFEqual(focused, target),
              !flag(target, kAXMinimizedAttribute), let windowFrame = frame(target) else { return nil }
        var native: [(Int, AXUIElement, CGRect)] = []
        for (slot, attribute) in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute].enumerated() {
            guard let button = element(target, attribute), flag(button, kAXEnabledAttribute) else { continue }
            guard AXUIElementGetTypeID() == CFGetTypeID(button), pid(button) == fixture.processIdentifier,
                  string(button, kAXRoleAttribute) == kAXButtonRole, let rect = frame(button), windowFrame.contains(rect) else { return nil }
            native.append((slot, button, rect))
        }
        guard native.map({ $0.0 }) == expectedSlots, let close = native.first(where: { $0.0 == 0 }) else { return nil }
        let rows = visibleRows()
        guard let ownRow = rows.first(where: { $0.id == expectedCGID && $0.pid == fixture.processIdentifier && $0.layer == 0 }),
              equal(ownRow.frame, windowFrame) else { return nil }
        for (_, button, rect) in native {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard rows.first(where: { $0.layer == 0 && $0.frame.contains(center) })?.id == expectedCGID,
                  hit(center, in: axApp).map({ CFEqual($0, button) }) == true else { return nil }
        }
        let union = native.dropFirst().reduce(native[0].2) { $0.union($1.2) }
        let panels = rows.filter { row in
            row.pid == trio.processIdentifier && row.layer == 3 && row.order < ownRow.order &&
            windowFrame.contains(row.frame) && row.frame.contains(union) &&
            row.frame.maxX <= native.last!.2.maxX + 5.5
        }
        guard panels.count == 1, let panel = panels.first,
              let red = hit(CGPoint(x: close.2.midX, y: close.2.midY)), isTrioButton(red, label: labels[0]),
              let redFrame = frame(red), panel.frame.insetBy(dx: -2, dy: -2).contains(redFrame) else { return nil }
        var found = Set<Int>()
        for x in stride(from: panel.frame.minX + 2, through: panel.frame.maxX - 2, by: 2) {
            guard let node = hit(CGPoint(x: x, y: union.midY)), pid(node) == trio.processIdentifier,
                  string(node, kAXRoleAttribute) == kAXButtonRole else { continue }
            guard let slot = labels.firstIndex(where: { isTrioButton(node, label: $0) }) else { return nil }
            found.insert(slot)
        }
        return found == Set(expectedSlots) ? (red, panel, expectedSlots) : nil
    }

    private func ownedWindows() -> [Int: AXUIElement]? {
        guard let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var result: [Int: AXUIElement] = [:]
        for window in windows {
            guard pid(window) == fixture.processIdentifier, string(window, kAXRoleAttribute) == kAXWindowRole,
                  let identifier = string(window, kAXIdentifierAttribute), identifier.hasPrefix(prefix),
                  let index = Int(identifier.dropFirst(prefix.count)), (0..<5).contains(index), result[index] == nil else { return nil }
            result[index] = window
        }
        return result
    }
    private func fixtureEvents() -> [[String: Any]] {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let launch = fixture?.launchDate?.timeIntervalSince1970 ?? 0
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["pid"] as? Int32 == fixture?.processIdentifier, (event["time"] as? Double ?? 0) >= launch - 2 else { return nil }
            return event
        }
    }
    private func closedIDs() -> [Int] { fixtureEvents().filter { $0["event"] as? String == "windowWillClose" }.compactMap { $0["window"] as? Int } }
    private func fixtureRunning() -> Bool { NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).contains { $0.processIdentifier == fixture.processIdentifier && !$0.isTerminated } }
    private func requireForeground() {
        guard fixtureRunning(), NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier else {
            stop("Fixture is no longer foreground; no activation, HID, or further AXPress attempted")
        }
    }
    private func isTrioButton(_ node: AXUIElement, label: String) -> Bool {
        pid(node) == trio.processIdentifier && string(node, kAXRoleAttribute) == kAXButtonRole && flag(node, kAXEnabledAttribute) &&
        [kAXTitleAttribute, kAXDescriptionAttribute].contains { string(node, $0) == label }
    }
    private func visibleRows() -> [Row] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.enumerated().compactMap { order, row in
            guard let id = row[kCGWindowNumber as String] as? Int, let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let layer = row[kCGWindowLayer as String] as? Int,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: dict) else { return nil }
            return Row(id: id, pid: pid, layer: layer, order: order, frame: frame)
        }
    }
    private func argument(_ name: String) -> String? { guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index+1) else { return nil }; return arguments[index+1] }
    private func value(_ node: AXUIElement, _ key: String) -> CFTypeRef? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else { return nil }; return value }
    private func element(_ node: AXUIElement, _ key: String) -> AXUIElement? { guard let value = value(node,key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }; return (value as! AXUIElement) }
    private func string(_ node: AXUIElement, _ key: String) -> String? { value(node,key) as? String }
    private func flag(_ node: AXUIElement, _ key: String) -> Bool { value(node,key) as? Bool == true }
    private func pid(_ node: AXUIElement) -> pid_t { var pid: pid_t = 0; AXUIElementGetPid(node,&pid); return pid }
    private func frame(_ node: AXUIElement) -> CGRect? {
        guard let p = value(node,kAXPositionAttribute), let s = value(node,kAXSizeAttribute), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin:point,size:size)
    }
    private func hit(_ point: CGPoint, in app: AXUIElement? = nil) -> AXUIElement? { var node: AXUIElement?; guard AXUIElementCopyElementAtPosition(app ?? AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&node) == .success else { return nil }; return node }
    private func equal(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX-b.minX) <= 1 && abs(a.minY-b.minY) <= 1 && abs(a.width-b.width) <= 1 && abs(a.height-b.height) <= 1 }
    private func settle(_ seconds: Double) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
    private func stop(_ reason: String) -> Never { report["passed"] = false; report["aborted"] = reason; finish(2) }
    private func finish(_ status: Int32) -> Never {
        report["steps"] = steps
        let data = (try? JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys])) ?? Data("{}".utf8)
        if let outputURL { try? data.write(to: outputURL,options:.atomic) }
        print(String(data:data,encoding:.utf8)!); exit(status)
    }
}
