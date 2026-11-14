import AppKit
import ApplicationServices

@main struct InspectFinder {
    @MainActor static func main() throws {
        let bundle = "com.apple.finder"
        var report: [String: Any] = ["bundleID": bundle, "generatedAt": ISO8601DateFormatter().string(from: Date()),
                                   "accessibilityTrusted": AXIsProcessTrusted(), "readOnly": true,
                                   "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
        func rect(_ r: CGRect) -> [String: CGFloat] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        func publish() throws {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: "build/finder-inspection.json"), options: .atomic)
            print(String(data: data, encoding: .utf8)!)
        }
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            report["result"] = "Finder unavailable or Accessibility absent"; try publish(); return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        let windows = AX.value(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let focused = AX.element(axApp, kAXFocusedWindowAttribute)
        report["pid"] = app.processIdentifier
        report["active"] = app.isActive
        report["regularActivationPolicy"] = app.activationPolicy == .regular
        report["windowCount"] = windows.count
        report["focusedWindowPresent"] = focused != nil
        let cg = SystemWindow.visible()
        report["visibleCGWindows"] = cg.filter { $0.pid == app.processIdentifier }.map {
            ["id": $0.id, "layer": $0.layer, "frame": rect($0.bounds)] as [String: Any]
        }
        let trioPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.allm4.Trio").map(\.processIdentifier))
        var windowReports: [[String: Any]] = []
        for (index, window) in windows.enumerated() {
            var row: [String: Any] = ["index": index, "focused": focused.map { AX.same($0, window) } ?? false,
                                      "role": AX.string(window, kAXRoleAttribute) ?? "missing",
                                      "subrole": AX.string(window, kAXSubroleAttribute) ?? "missing",
                                      "minimized": AX.flag(window, kAXMinimizedAttribute),
                                      "positionSettable": AX.isSettable(window, kAXPositionAttribute),
                                      "sizeSettable": AX.isSettable(window, kAXSizeAttribute)]
            let attributes = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
            let buttons = attributes.compactMap { AX.element(window, $0) }
            let frames = buttons.compactMap { AX.rect($0) }
            row["controls"] = attributes.map { attribute -> [String: Any] in
                guard let button = AX.element(window, attribute) else { return ["attribute": attribute, "present": false] }
                var result: [String: Any] = ["attribute": attribute, "present": true, "pid": AX.pid(button),
                                             "role": AX.string(button, kAXRoleAttribute) ?? "missing",
                                             "subrole": AX.string(button, kAXSubroleAttribute) ?? "missing",
                                             "enabled": AX.flag(button, kAXEnabledAttribute)]
                if let frame = AX.rect(button) { result["frame"] = rect(frame) }
                return result
            }
            let children = AX.value(window, kAXChildrenAttribute) as? [AXUIElement]
            row["immediateChildrenRoles"] = children?.map { AX.string($0, kAXRoleAttribute) ?? "missing" } ?? []
            row["childrenAvailable"] = children != nil
            row["hasSheet"] = children?.contains { AX.string($0, kAXRoleAttribute) == kAXSheetRole } ?? false
            guard let frame = AX.rect(window) else { row["result"] = "Invalid window geometry"; windowReports.append(row); continue }
            row["frame"] = rect(frame)
            let matches = cg.filter { $0.pid == app.processIdentifier && $0.layer == 0 && SystemWindow.close($0.bounds, frame) }
            row["uniqueCGMatchCount"] = matches.count
            if let screen = WindowTarget.screen(for: frame) {
                row["screenFrame"] = rect(WindowTarget.toAX(screen.frame))
                row["matchesFullDisplayFrame"] = SystemWindow.close(frame, WindowTarget.toAX(screen.frame), tolerance: 1)
            }
            guard buttons.count == 3, frames.count == 3, matches.count == 1 else {
                row["result"] = "Control geometry or CG identity is unavailable"; windowReports.append(row); continue
            }
            guard let region = TrioLayout.availableRegion(window: frame, controls: frames) else {
                row["result"] = "No strict available region"; windowReports.append(row); continue
            }
            row["region"] = rect(region)
            let target = WindowTarget(pid: app.processIdentifier, window: window, id: matches[0].id, frame: frame,
                                      buttons: buttons, buttonFrames: frames, name: "Finder")
            let obstacles = target.obstacles(for: region)
            row["obstacleSurveyCompleted"] = obstacles != nil
            row["obstacles"] = obstacles?.map(rect) ?? []
            if let obstacles {
                row["layouts"] = [1.0,1.5,3.0,5.0].map { scale -> [String: Any] in
                    switch TrioLayout.calculate(window: frame, controls: frames, requestedScale: scale, obstacles: obstacles) {
                    case .success(let layout): return ["requested": scale, "effective": layout.effectiveScale, "frame": rect(layout.frame)]
                    case .failure(let error): return ["requested": scale, "failure": error.reason]
                    }
                }
            }
            if let targetIndex = cg.firstIndex(where: { $0.id == matches[0].id }) {
                row["coveringNormalWindows"] = cg[..<targetIndex].filter {
                    $0.pid != app.processIdentifier && !trioPIDs.contains($0.pid) && $0.layer == 0 && $0.bounds.intersects(region)
                }.map { ["pid": $0.pid, "id": $0.id, "frame": rect($0.bounds)] as [String: Any] }
            }
            // Explain incomplete scans with geometry/roles only, never names or text.
            if obstacles == nil {
                var issues: [[String: Any]] = [], leaves: [[String: Any]] = []
                var visited = 0
                let start = ProcessInfo.processInfo.systemUptime
                let containers: Set<String> = [kAXWindowRole,kAXGroupRole,kAXToolbarRole,kAXSplitGroupRole,kAXScrollAreaRole,
                                                kAXLayoutAreaRole,kAXListRole,kAXRadioGroupRole,"AXWebArea"]
                func trace(_ node: AXUIElement, path: [Int]) {
                    guard issues.count < 12, visited < 400, ProcessInfo.processInfo.systemUptime-start < 0.6 else { return }
                    visited += 1
                    if buttons.contains(where: { AX.same($0,node) }) { return }
                    let role = AX.string(node,kAXRoleAttribute) ?? "missing"
                    guard let nodeFrame = AX.rect(node) else {
                        issues.append(["path":path,"role":role,"reason":"Missing, zero, or invalid frame before intersection pruning"]); return
                    }
                    guard region.intersects(nodeFrame) else { return }
                    guard containers.contains(role) else { leaves.append(["path":path,"role":role,"frame":rect(nodeFrame)]); return }
                    guard path.count < 32 else { issues.append(["path":path,"role":role,"reason":"Depth limit"]); return }
                    var raw: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(node,kAXChildrenAttribute as CFString,&raw)
                    guard error == .success, let nodes = raw as? [AXUIElement] else {
                        issues.append(["path":path,"role":role,"frame":rect(nodeFrame),"reason":"Container children unavailable","axError":error.rawValue]); return
                    }
                    for (index,child) in nodes.enumerated() { trace(child,path:path+[index]) }
                }
                trace(window,path:[])
                row["surveyDiagnostic"] = ["visited":visited,"duration":ProcessInfo.processInfo.systemUptime-start,"issues":issues,"leavesInRegion":leaves]
            }
            windowReports.append(row)
        }
        report["windows"] = windowReports
        try publish()
    }
}
