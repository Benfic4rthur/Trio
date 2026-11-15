import AppKit
import ApplicationServices
import TrioCore

/// Test-only engine host. It controls only the fixture at this exact build path.
/// Workspace sleep/session notifications are posted locally, never to the OS.
@main struct ValidateWindowRecovery {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let baseline = CommandLine.arguments.contains("--baseline")
        let installed = CommandLine.arguments.contains("--installed")
        let external = baseline || installed
        let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/fixtures/TrioAlignmentFixture.app").resolvingSymlinksInPath()
        let fixtureID = "com.allm4.TrioFixture.Alignment"
        guard Bundle(url: fixtureURL)?.bundleIdentifier == fixtureID, AXIsProcessTrusted() else { fatalError("Owned fixture or existing Accessibility unavailable") }
        for previous in NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID) {
            guard previous.bundleURL?.resolvingSymlinksInPath() == fixtureURL else { fatalError("Unexpected fixture path") }
            previous.terminate()
            for _ in 0..<20 { if previous.isTerminated { break }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        var launched: NSRunningApplication?
        var launchError: Error?
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: fixtureURL, configuration: configuration) { result, error in launched = result; launchError = error }
        func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        for _ in 0..<40 { if launched != nil || launchError != nil { break }; wait(0.1) }
        guard let fixture = launched, fixture.bundleURL?.resolvingSymlinksInPath() == fixtureURL else { fatalError("Fixture launch failed: \(String(describing: launchError))") }
        defer { fixture.terminate() }
        wait(1.0)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != fixture.processIdentifier {
            _ = fixture.activate(options: [.activateAllWindows])
            wait(0.4)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier else { fatalError("Fixture is not foreground; no actions allowed") }
        let axApp = AXUIElementCreateApplication(fixture.processIdentifier)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute), let initialFrame = AX.rect(window) else { fatalError("Fixture window unavailable") }
        let suite = "TrioValidation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoMaximizeNewWindows")
        defaults.set(1.3, forKey: "controlScale")
        defer { defaults.removePersistentDomain(forName: suite) }
        var statuses: [String] = []
        let engine = TrioEngine(settings: SettingsStore(defaults: defaults), onStatus: { statuses.append($0) }, onOpen: {})
        if !external { engine.start(); wait(0.4) }
        defer { if !external { engine.stop() } }
        let overlayPID = external ? NSRunningApplication.runningApplications(withBundleIdentifier: "com.allm4.Trio").first!.processIdentifier : getpid()
        func panel() -> SystemWindow? { SystemWindow.visible().first { $0.pid == overlayPID && $0.layer == 3 } }
        func rowY() -> CGFloat? {
            let frames = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute].compactMap { AX.element(window, $0).flatMap(AX.rect) }
            guard frames.count == 3 else { return nil }; return frames.map(\.midY).reduce(0,+)/3
        }
        func aligned() -> Bool { guard let p = panel(), let y = rowY() else { return false }; return abs(p.bounds.midY-y) < 0.6 }
        var report: [String: Any] = ["baseline": baseline, "fixturePID": fixture.processIdentifier, "overlayPID": overlayPID]
        report["installed"] = installed
        let initiallyAligned = aligned()
        report["alignedBeforeShift"] = initiallyAligned
        report["beforeRowY"] = rowY(); report["beforePanelY"] = panel()?.bounds.midY
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(fixtureID + ".shiftControls"), object: nil, userInfo: nil, deliverImmediately: true)
        wait(0.65)
        report["afterRowY"] = rowY(); report["afterPanelY"] = panel()?.bounds.midY
        report["outerWindowFrameUnchanged"] = AX.rect(window).map { SystemWindow.close($0, initialFrame, tolerance: 0.1) } ?? false
        report["alignedAfterNativeRowShift"] = aligned()
        var passed = initiallyAligned && (baseline ? !aligned() : aligned())
        if !baseline {
            let center = NSWorkspace.shared.notificationCenter
            var cycles: [[String: Any]] = []
            for (sleep, wake) in (installed ? [] : [(NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                                  (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
                                  (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification)]) {
                center.post(name: sleep, object: NSWorkspace.shared); wait(0.06)
                let hidden = panel() == nil
                center.post(name: wake, object: NSWorkspace.shared)
                var recovered = false
                for _ in 0..<35 { wait(0.1); if aligned() { recovered = true; break } }
                cycles.append(["suspend": sleep.rawValue, "hiddenWhileSuspended": hidden, "recoveredWithoutClick": recovered])
                passed = passed && hidden && recovered
            }
            report["simulatedWorkspaceCycles"] = cycles
            // Content clicks are verified against the fixture's actual topmost
            // CG window and AX hit before every event. No arbitrary PID/point.
            var absentSamples = 0
            for _ in 0..<10 {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
                      let frame = AX.rect(window) else { fatalError("Foreground changed; no clicks sent") }
                let point = CGPoint(x: frame.midX, y: frame.minY + min(200, frame.height/2))
                guard SystemWindow.visible().first(where: { $0.layer == 0 && $0.bounds.contains(point) })?.pid == fixture.processIdentifier,
                      AX.at(point).map({ AX.pid($0) == fixture.processIdentifier }) == true else { fatalError("Fixture content hit not confirmed") }
                let source = CGEventSource(stateID: .hidSystemState)
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
                    event.setIntegerValueField(.mouseEventClickState, value: 1); event.post(tap: .cghidEventTap)
                }
                for _ in 0..<6 { wait(0.02); if panel() == nil { absentSamples += 1 } }
            }
            report["contentClickCount"] = 10; report["missingPanelSamplesAcrossClicks"] = absentSamples
            passed = passed && absentSamples == 0
            if installed {
                func clickTrio(_ attribute: String) {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
                          let button = AX.element(window, attribute), let rect = AX.rect(button), let p = panel() else { fatalError("Fixture/control unavailable") }
                    let point = CGPoint(x: rect.midX, y: rect.midY)
                    guard p.bounds.contains(point), AX.at(point).map({ AX.pid($0) == overlayPID }) == true,
                          SystemWindow.visible().first(where: { $0.layer == 0 && $0.bounds.contains(point) })?.pid == fixture.processIdentifier else { fatalError("Trio and fixture hit proof failed") }
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
                        event.setIntegerValueField(.mouseEventClickState, value: 1); event.post(tap: .cghidEventTap)
                    }
                    wait(0.55)
                }
                let greenBefore = AX.rect(window)!
                clickTrio(kAXZoomButtonAttribute)
                let greenChanged = AX.rect(window).map { !SystemWindow.close($0, greenBefore, tolerance: 1) } ?? false
                clickTrio(kAXZoomButtonAttribute)
                let greenRestored = AX.rect(window).map { SystemWindow.close($0, greenBefore, tolerance: 1) } ?? false
                report["greenChangedThenRestored"] = greenChanged && greenRestored
                clickTrio(kAXMinimizeButtonAttribute)
                let minimized = AX.flag(window, kAXMinimizedAttribute)
                report["yellowMinimizedFixture"] = minimized
                _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                var activated = false
                NSWorkspace.shared.openApplication(at: fixtureURL, configuration: configuration) { _, _ in activated = true }
                for _ in 0..<30 { wait(0.1); if activated && NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier && aligned() { break } }
                let smartClose = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.smartclose.app").isEmpty
                report["smartCloseRunning"] = smartClose
                clickTrio(kAXCloseButtonAttribute)
                for _ in 0..<20 { if fixture.isTerminated { break }; wait(0.1) }
                let closed = fixture.isTerminated || (AX.value(axApp, kAXWindowsAttribute) as? [AXUIElement])?.isEmpty == true
                report["redClosedFixture"] = closed
                report["smartCloseTerminatedFixture"] = fixture.isTerminated
                report["trioSurvived"] = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.allm4.Trio").isEmpty
                passed = passed && greenChanged && greenRestored && minimized && closed && (!smartClose || fixture.isTerminated)
            }
        }
        report["passed"] = passed
        report["statuses"] = statuses
        let output = baseline ? "build/recovery-baseline.json" : (installed ? "build/recovery-installed.json" : "build/recovery-fixed.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("Validation \(baseline ? "baseline" : "fixed"): \(passed ? "PASS" : "FAIL") — \(output)")
        if !passed { exit(2) }
    }
}
