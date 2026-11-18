import AppKit
import ApplicationServices
import TrioCore

// Read-only structural diagnostics. Never reads document titles, values or text,
// requests permissions, activates an app, or sends input to another process.
@main struct InspectAvailability {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        func rect(_ r: CGRect) -> [String: CGFloat] { ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height] }
        let windows = SystemWindow.visible()
        let front = NSWorkspace.shared.frontmostApplication
        var reports: [[String: Any]] = []
        for app in NSWorkspace.shared.runningApplications where ["com.anthropic.claudefordesktop", "com.openai.codex", "com.microsoft.edgemac", "com.apple.finder"].contains(app.bundleIdentifier ?? "") {
            var row: [String: Any] = ["bundleID":app.bundleIdentifier!,"pid":app.processIdentifier,"frontmost":app.processIdentifier == front?.processIdentifier]
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax,0.15)
            if let window = AX.element(ax,kAXFocusedWindowAttribute) {
                row["subrole"] = AX.string(window,kAXSubroleAttribute)
                row["minimized"] = AX.flag(window,kAXMinimizedAttribute)
                if let frame = AX.rect(window) {
                    row["frame"] = rect(frame)
                    let buttons = [kAXCloseButtonAttribute,kAXMinimizeButtonAttribute,kAXZoomButtonAttribute].compactMap { AX.element(window,$0) }
                    row["buttons"] = buttons.map { b -> [String:Any] in
                        var r: [String:Any] = ["enabled":AX.flag(b,kAXEnabledAttribute),"role":AX.string(b,kAXRoleAttribute) ?? "unknown"]
                        if let f = AX.rect(b) { r["frame"] = rect(f) }
                        return r
                    }
                    let frames = buttons.compactMap(AX.rect)
                    let matches = windows.filter { $0.pid == app.processIdentifier && $0.layer == 0 && SystemWindow.close($0.bounds,frame) }
                    row["CGMatches"] = matches.map(\.id)
                    if buttons.count == 3, frames.count == 3, let id = matches.first?.id {
                        let candidate = WindowTarget(pid:app.processIdentifier,window:window,id:id,frame:frame,buttons:buttons,buttonFrames:frames,name:"diagnostic")
                        if let reserve = TrioLayout.availableRegion(window:frame,controls:frames) {
                            row["reserve"] = rect(reserve)
                            if let obstacles = candidate.obstacles(for:reserve) {
                                row["obstacles"] = obstacles.map(rect)
                                switch TrioLayout.calculate(window:frame,controls:frames,requestedScale:1.3,obstacles:obstacles) {
                                case .success(let layout): row["effectiveScale"] = layout.effectiveScale;row["mask"] = rect(layout.frame)
                                case .failure(let error): row["layoutFailure"] = String(describing:error)
                                }
                            } else {
                                row["surveyIncomplete"] = true
                                var visited = 0
                                var failures: [[String:Any]] = []
                                let started = ProcessInfo.processInfo.systemUptime
                                let containers: Set<String> = [kAXWindowRole,kAXGroupRole,kAXToolbarRole,kAXSplitGroupRole,kAXScrollAreaRole,kAXLayoutAreaRole,kAXListRole,kAXRadioGroupRole,"AXWebArea"]
                                func trace(_ node: AXUIElement, _ depth: Int) {
                                    guard failures.isEmpty else { return }
                                    visited += 1
                                    var result: [String:Any] = ["depth":depth,"visited":visited,"elapsed":ProcessInfo.processInfo.systemUptime-started,"role":AX.string(node,kAXRoleAttribute) ?? "unavailable"]
                                    guard depth < 32, visited < 400, ProcessInfo.processInfo.systemUptime-started < 0.3 else { result["failure"]="budget";failures.append(result);return }
                                    if buttons.contains(where: { AX.same($0,node) }) { return }
                                    guard let f = AX.rect(node) else {
                                        result["failure"]="geometry"
                                        for attribute in [kAXPositionAttribute,kAXSizeAttribute] {
                                            var v:CFTypeRef?
                                            result[attribute+"Error"] = AXUIElementCopyAttributeValue(node,attribute as CFString,&v).rawValue
                                            if let v, CFGetTypeID(v)==AXValueGetTypeID() {
                                                var p=CGPoint.zero,s=CGSize.zero
                                                if AXValueGetValue(v as! AXValue,.cgPoint,&p) { result[attribute] = [p.x,p.y] }
                                                if AXValueGetValue(v as! AXValue,.cgSize,&s) { result[attribute] = [s.width,s.height] }
                                            }
                                        }
                                        failures.append(result);return
                                    }
                                    guard reserve.intersects(f) else { return }
                                    guard let role=AX.string(node,kAXRoleAttribute),containers.contains(role) else { return }
                                    var v:CFTypeRef?
                                    let error=AXUIElementCopyAttributeValue(node,kAXChildrenAttribute as CFString,&v)
                                    guard error == .success, let children=v as? [AXUIElement] else { result["failure"]="children";result["error"]=error.rawValue;failures.append(result);return }
                                    for child in children { trace(child,depth+1) }
                                }
                                trace(window,0)
                                row["surveyFailure"] = failures
                            }
                        }
                    }
                }
            } else { row["focusedWindowUnavailable"] = true }
            reports.append(row)
        }
        let trio = NSRunningApplication.runningApplications(withBundleIdentifier:"com.allm4.Trio").first
        let report: [String:Any] = ["trusted":AXIsProcessTrusted(),"frontmostBundleID":front?.bundleIdentifier ?? "unknown","frontCandidateAvailable":WindowTarget.focused() != nil,"apps":reports,"trioPanels":windows.filter { $0.pid == trio?.processIdentifier && $0.layer == 3 }.map { ["id":$0.id,"bounds":rect($0.bounds)] }]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted])
        if CommandLine.arguments.count > 1 { try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        print(String(decoding:data,as:UTF8.self))
    }
}
