import AppKit
import ApplicationServices

/// One visible, empty Edge window in an exclusively owned temporary profile.
/// Refuses to launch while any normal Edge instance exists. No HID, AppleScript,
/// browsing, personal-profile access, or Trio changes. --native-close presses
/// only the verified original AXCloseButton of the disposable Edge instance.
@main @MainActor struct VerifyEdgeClose {
    static func main() { EdgeCloseVerification().run() }
}

@MainActor private final class EdgeCloseVerification {
    private let edgeID = "com.microsoft.edgemac"
    private let trioID = "com.allm4.Trio"
    private let edgeURL = URL(fileURLWithPath: "/Applications/Microsoft Edge.app")
    private let executable = URL(fileURLWithPath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
    private let arguments = ProcessInfo.processInfo.arguments
    private let process = Process()
    private var testApp: NSRunningApplication?
    private var trio: NSRunningApplication!
    private var outputURL: URL?
    private var temporaryRoot: URL?
    private let ownershipToken = UUID().uuidString
    private var report: [String: Any] = ["test": "owned-empty-edge-close", "HIDPosted": false,
                                       "pressedOriginalEdgeButton": false, "URLRequested": "about:blank"]
    private var observations: [[String: Any]] = []

    private struct Row {
        let id: Int, pid: pid_t, layer: Int, order: Int
        let frame: CGRect
        var json: [String: Any] { ["id": id, "pid": pid, "layer": layer, "frame": rect(frame)] }
    }

    func run() {
        report["generatedAt"] = ISO8601DateFormatter().string(from: Date())
        let nativeClose = arguments.contains("--native-close")
        report["requestedAction"] = nativeClose ? "original-owned-Edge-close-AXPress" : "Trio-red-AXPress"
        guard let output = argument("--output"), output.hasPrefix("/") else { finish("Use --output ABSOLUTE.json", code: 2) }
        outputURL = URL(fileURLWithPath: output)
        guard AXIsProcessTrusted() else { finish("Accessibility is not already authorized; no permission requested", code: 2) }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: edgeID).isEmpty else {
            finish("An Edge instance already exists; no launch or action attempted", code: 2)
        }
        let trios = NSRunningApplication.runningApplications(withBundleIdentifier: trioID)
        guard trios.count == 1, trios[0].bundleURL?.resolvingSymlinksInPath().path == "/Applications/Trio.app",
              FileManager.default.isExecutableFile(atPath: executable.path),
              Bundle(url: edgeURL)?.bundleIdentifier == edgeID else { finish("Installed Trio or Edge identity unavailable", code: 2) }
        trio = trios[0]
        let trioInfo = Bundle(url: trio.bundleURL!)?.infoDictionary ?? [:]
        let version = trioInfo["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = trioInfo["CFBundleVersion"] as? String ?? "unknown"
        report["trioVersion"] = version; report["trioBuild"] = build; report["trioPID"] = trio.processIdentifier
        report["edgeVersion"] = Bundle(url: edgeURL)?.infoDictionary?["CFBundleShortVersionString"]
        if let expected = argument("--expected-version"), version != expected { finish("Installed Trio version differs from expectation; no launch", code: 2) }
        if let expected = argument("--expected-build"), build != expected { finish("Installed Trio build differs from expectation; no launch", code: 2) }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("trio-edge-close-" + ownershipToken, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            temporaryRoot = root
            try ownershipToken.write(to: root.appendingPathComponent(".trio-owned"), atomically: true, encoding: .utf8)
            let profile = root.appendingPathComponent("UserData", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
            // Unique user-data-dir prevents Chromium's existing-profile singleton
            // routing. Additional flags only affect this disposable invocation.
            process.executableURL = executable
            process.arguments = ["--user-data-dir=" + profile.path, "--no-first-run", "--no-default-browser-check",
                                 "--disable-sync", "--disable-extensions",
                                 "--disable-background-networking", "--disable-component-update", "--new-window", "about:blank"]
            report["launchFlags"] = ["--user-data-dir=<owned-temporary-profile>"] + Array(process.arguments!.dropFirst())
            report["backgroundModeForcedOff"] = false
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            // Recheck at the last boundary before launching our own instance.
            guard NSRunningApplication.runningApplications(withBundleIdentifier: edgeID).isEmpty else { finish("Edge appeared before launch; no launch", code: 2) }
            try process.run()
            report["launchedMainPID"] = process.processIdentifier
            report["temporaryProfileOwned"] = true
        } catch { finish("Could not prepare/launch the disposable Edge instance: \(error.localizedDescription)", code: 2) }

        let axEdge = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(axEdge, 0.2)
        let startupDeadline = Date().addingTimeInterval(15)
        var proof: (AXUIElement, AXUIElement, Row, Row)?
        while process.isRunning, Date() < startupDeadline {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: edgeID)
            guard running.allSatisfy({ $0.processIdentifier == process.processIdentifier }) else { finish("Another Edge instance appeared; no press", code: 2) }
            if let app = running.first, app.processIdentifier == process.processIdentifier,
               app.executableURL?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() {
                testApp = app
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
                    proof = verifyRed(axEdge: axEdge)
                    if proof != nil { break }
                }
            }
            settle(0.08)
        }
        guard let (window, red, edgeRow, trioRow) = proof else {
            observations.append(snapshot(axEdge: axEdge, elapsed: 0))
            finish("One foreground empty-profile Edge window and its Trio red control could not be proven; no press", code: 2)
        }
        report["edgeTargetCGWindowID"] = edgeRow.id
        report["trioOverlayCGWindowID"] = trioRow.id
        observations.append(snapshot(axEdge: axEdge, elapsed: 0))
        guard ownAppIsForeground(), let recheck = verifyRed(axEdge: axEdge),
              CFEqual(recheck.0, window), CFEqual(recheck.1, red), recheck.2.id == edgeRow.id, recheck.3.id == trioRow.id else {
            finish("Focus, owned process, or window identity changed immediately before press", code: 2)
        }
        let actionButton: AXUIElement
        if nativeClose {
            // Retain this exact window's original button. The public Edge-scoped
            // hit proves its identity even while Trio covers its visible pixels.
            guard let original = element(window,kAXCloseButtonAttribute),
                  pid(original) == process.processIdentifier,
                  string(original,kAXRoleAttribute) == kAXButtonRole,
                  string(original,kAXSubroleAttribute) == kAXCloseButtonSubrole,
                  flag(original,kAXEnabledAttribute), let originalFrame = frame(original),
                  hit(CGPoint(x:originalFrame.midX,y:originalFrame.midY),in:axEdge)
                    .map({CFEqual($0,original)}) == true,
                  ownAppIsForeground(),
                  element(axEdge,kAXFocusedWindowAttribute).map({CFEqual($0,window)}) == true else {
                finish("Original owned Edge close button identity changed; no press", code: 2)
            }
            actionButton = original
        } else { actionButton = red }
        let pressedAt = ProcessInfo.processInfo.systemUptime
        let pressed = AXUIElementPerformAction(actionButton, kAXPressAction as CFString)
        report[nativeClose ? "nativeCloseAXPressResult" : "trioRedAXPressResult"] = pressed.rawValue
        report["pressedOriginalEdgeButton"] = nativeClose
        report["pressedTrioRedButton"] = !nativeClose
        guard pressed == .success else { finish("Verified action button refused AXPress", code: 1) }
        while process.isRunning, ProcessInfo.processInfo.systemUptime - pressedAt < 9 {
            observations.append(snapshot(axEdge: axEdge, elapsed: ProcessInfo.processInfo.systemUptime - pressedAt))
            settle(0.1)
        }
        report["mainExitedBeforeCleanup"] = !process.isRunning
        if !process.isRunning {
            report["mainExitDelaySeconds"] = ProcessInfo.processInfo.systemUptime - pressedAt
            report["mainTerminationStatusBeforeCleanup"] = process.terminationStatus
            report["mainTerminationReasonBeforeCleanup"] = process.terminationReason == .exit ? "exit" : "signal"
        }
        // Keep the post-exit CG rows as evidence of retained backing stores or
        // overlay transitions. A visible Trio panel after focus changes is not,
        // by itself, proof that it still targets Edge.
        for delay in [0.0, 0.2, 0.6] {
            settle(delay)
            observations.append(snapshot(axEdge: axEdge, elapsed: ProcessInfo.processInfo.systemUptime - pressedAt))
        }
        report["productOutcome"] = process.isRunning ? "main-still-running-after-nine-seconds" : "main-exited"
        report["trioProcessRunningAfter"] = NSRunningApplication.runningApplications(withBundleIdentifier: trioID)
            .contains(where: { $0.processIdentifier == trio.processIdentifier && !$0.isTerminated })
        let success = !process.isRunning
        finish(nil, code: success ? 0 : 1)
    }

    private func verifyRed(axEdge: AXUIElement) -> (AXUIElement, AXUIElement, Row, Row)? {
        guard ownAppIsForeground(), let windows = value(axEdge, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1,
              let window = windows.first, let focused = element(axEdge, kAXFocusedWindowAttribute), CFEqual(window, focused),
              pid(window) == process.processIdentifier, string(window, kAXRoleAttribute) == kAXWindowRole,
              !flag(window,kAXMinimizedAttribute), let windowFrame = frame(window),
              let close = element(window,kAXCloseButtonAttribute), pid(close) == process.processIdentifier,
              string(close,kAXRoleAttribute) == kAXButtonRole, flag(close,kAXEnabledAttribute), let closeFrame = frame(close),
              windowFrame.contains(closeFrame) else { return nil }
        let closePoint = CGPoint(x:closeFrame.midX,y:closeFrame.midY)
        guard hit(closePoint,in:axEdge).map({CFEqual($0,close)}) == true else { return nil }
        let rows = cgRows(visibleOnly:true)
        let matching = rows.filter { $0.pid == process.processIdentifier && $0.layer == 0 && equal($0.frame,windowFrame) }
        guard matching.count == 1, let edge = matching.first,
              rows.first(where:{$0.layer == 0 && $0.frame.contains(closePoint)})?.id == edge.id else { return nil }
        var nativeRects: [CGRect] = []
        for key in [kAXCloseButtonAttribute,kAXMinimizeButtonAttribute,kAXZoomButtonAttribute] {
            if let button = element(window,key), flag(button,kAXEnabledAttribute), let rect = frame(button) { nativeRects.append(rect) }
        }
        guard !nativeRects.isEmpty else { return nil }
        let union = nativeRects.dropFirst().reduce(nativeRects[0]){$0.union($1)}
        let panels = rows.filter { $0.pid == trio.processIdentifier && $0.layer == 3 && $0.order < edge.order &&
            windowFrame.contains($0.frame) && $0.frame.contains(union) && $0.frame.maxX <= union.maxX+5.5 }
        let axTrio = AXUIElementCreateApplication(trio.processIdentifier)
        AXUIElementSetMessagingTimeout(axTrio,0.2)
        guard panels.count == 1, let panel = panels.first,
              let red = hit(closePoint,in:axTrio), pid(red) == trio.processIdentifier,
              string(red,kAXRoleAttribute) == kAXButtonRole, flag(red,kAXEnabledAttribute),
              [kAXTitleAttribute,kAXDescriptionAttribute].contains(where:{string(red,$0) == "Fechar janela"}),
              let redFrame = frame(red), panel.frame.insetBy(dx:-2,dy:-2).contains(redFrame),
              hit(closePoint).map({CFEqual($0,red)}) == true,
              element(axEdge,kAXFocusedWindowAttribute).map({CFEqual($0,window)}) == true else { return nil }
        return(window,red,edge,panel)
    }

    private func snapshot(axEdge:AXUIElement,elapsed:Double)->[String:Any] {
        var raw:CFTypeRef?
        let error=AXUIElementCopyAttributeValue(axEdge,kAXWindowsAttribute as CFString,&raw)
        let windows=raw as? [AXUIElement]
        let ownPIDs:Set<pid_t>=[process.processIdentifier,trio.processIdentifier]
        return ["elapsedSeconds":elapsed,"mainProcessRunning":process.isRunning,
                "testAppIsForeground":NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier,
                "AXWindowsResult":error.rawValue,"AXWindowCount":windows?.count ?? -1,
                "AXWindows":(windows ?? []).map { window -> [String:Any] in
                    var item:[String:Any]=["pid":pid(window),"role":string(window,kAXRoleAttribute) ?? "unavailable",
                                          "subrole":string(window,kAXSubroleAttribute) ?? "unavailable",
                                          "minimized":flag(window,kAXMinimizedAttribute)]
                    if let rect=frame(window){item["frame"]=Self.rect(rect)}
                    return item
                },
                "visibleCGWindows":cgRows(visibleOnly:true).filter{ownPIDs.contains($0.pid)}.map(\.json),
                "allCGWindows":cgRows(visibleOnly:false).filter{ownPIDs.contains($0.pid)}.map(\.json)]
    }
    private func ownAppIsForeground()->Bool {
        guard process.isRunning, let testApp, testApp.processIdentifier == process.processIdentifier,
              !testApp.isTerminated, testApp.executableURL?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath(),
              NSRunningApplication.runningApplications(withBundleIdentifier:edgeID).allSatisfy({$0.processIdentifier == process.processIdentifier}) else{return false}
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
    }
    private func cleanup() {
        guard let root=temporaryRoot else{return}
        if process.isRunning {
            report["explicitCleanupRequested"]=true
            if let testApp, testApp.processIdentifier == process.processIdentifier,
               testApp.executableURL?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() {
                report["cleanupTerminateAccepted"]=testApp.terminate()
            } else { process.terminate() }
            let deadline=Date().addingTimeInterval(3)
            while process.isRunning,Date()<deadline {settle(0.05)}
            if process.isRunning {
                // Only our still-running child can reach this fallback. Never
                // locate a replacement application by bundle identifier.
                report["cleanupForceRequested"]=true
                if let testApp, !testApp.isTerminated { _=testApp.forceTerminate() }
                else { process.terminate() }
                let forced=Date().addingTimeInterval(2)
                while process.isRunning,Date()<forced {settle(0.05)}
            }
        }
        report["mainStoppedAfterCleanup"] = !process.isRunning
        guard !process.isRunning else { report["temporaryProfileRemoved"]=false;report["retainedOwnedProfileRoot"]=root.path;return }
        settle(0.4)
        let marker=root.appendingPathComponent(".trio-owned")
        guard root.lastPathComponent == "trio-edge-close-"+ownershipToken,
              (try? String(contentsOf:marker,encoding:.utf8)) == ownershipToken,
              (try? root.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == false else {
            report["temporaryProfileRemoved"]=false;return
        }
        do {try FileManager.default.removeItem(at:root);report["temporaryProfileRemoved"]=true}
        catch {report["temporaryProfileRemoved"]=false;report["retainedOwnedProfileRoot"]=root.path}
    }
    private func finish(_ error:String?,code:Int32)->Never {
        if let error {report["aborted"]=error}
        cleanup();report["observations"]=observations
        let data=(try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])) ?? Data("{}".utf8)
        if let outputURL {try? data.write(to:outputURL,options:.atomic)}
        print(String(data:data,encoding:.utf8)!);exit(code)
    }
    private func cgRows(visibleOnly:Bool)->[Row] {
        let options:CGWindowListOption=visibleOnly ? [.optionOnScreenOnly,.excludeDesktopElements] : [.optionAll,.excludeDesktopElements]
        let rows=CGWindowListCopyWindowInfo(options,kCGNullWindowID) as? [[String:Any]] ?? []
        return rows.enumerated().compactMap {order,row in
            guard let id=row[kCGWindowNumber as String] as? Int,let pid=row[kCGWindowOwnerPID as String] as? Int32,
                  let layer=row[kCGWindowLayer as String] as? Int,let dict=row[kCGWindowBounds as String] as? NSDictionary,
                  let frame=CGRect(dictionaryRepresentation:dict) else{return nil}
            return Row(id:id,pid:pid,layer:layer,order:order,frame:frame)
        }
    }
    private func argument(_ key:String)->String? {guard let i=arguments.firstIndex(of:key),arguments.indices.contains(i+1) else{return nil};return arguments[i+1]}
    private func value(_ node:AXUIElement,_ key:String)->CFTypeRef? {var v:CFTypeRef?;guard AXUIElementCopyAttributeValue(node,key as CFString,&v) == .success else{return nil};return v}
    private func element(_ node:AXUIElement,_ key:String)->AXUIElement? {guard let v=value(node,key),CFGetTypeID(v) == AXUIElementGetTypeID() else{return nil};return(v as! AXUIElement)}
    private func string(_ node:AXUIElement,_ key:String)->String? {value(node,key) as? String}
    private func flag(_ node:AXUIElement,_ key:String)->Bool {value(node,key) as? Bool == true}
    private func pid(_ node:AXUIElement)->pid_t {var p:pid_t=0;AXUIElementGetPid(node,&p);return p}
    private func frame(_ node:AXUIElement)->CGRect? {
        guard let p=value(node,kAXPositionAttribute),let s=value(node,kAXSizeAttribute),CFGetTypeID(p) == AXValueGetTypeID(),CFGetTypeID(s) == AXValueGetTypeID() else{return nil}
        var point=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size),
              point.x.isFinite,point.y.isFinite,size.width.isFinite,size.height.isFinite,size.width>0,size.height>0 else{return nil}
        return CGRect(origin:point,size:size)
    }
    private func hit(_ point:CGPoint,in app:AXUIElement?=nil)->AXUIElement? {var node:AXUIElement?;guard AXUIElementCopyElementAtPosition(app ?? AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&node) == .success else{return nil};return node}
    private func equal(_ a:CGRect,_ b:CGRect)->Bool {abs(a.minX-b.minX)<=1 && abs(a.minY-b.minY)<=1 && abs(a.width-b.width)<=1 && abs(a.height-b.height)<=1}
    nonisolated private static func rect(_ r:CGRect)->[String:CGFloat] {["x":r.minX,"y":r.minY,"width":r.width,"height":r.height]}
    private func settle(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
}
