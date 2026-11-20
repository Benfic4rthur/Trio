import AppKit
import ApplicationServices

/// Last-window handling for Trio's red button and observed Edge window destruction.
@MainActor final class WindowClosing {
    private final class Request {
        let app: NSRunningApplication
        let window: AXUIElement
        let id: CGWindowID
        let token = UUID()
        var survey = UUID()
        var quitRequested = false

        init(app: NSRunningApplication, window: AXUIElement, id: CGWindowID) {
            self.app = app
            self.window = window
            self.id = id
        }
    }
    private var pending: [pid_t: Request] = [:]
    private var observedEdgeWindows: [pid_t: Request] = [:]
    private let mayQuitOnLastWindow: (NSRunningApplication) -> Bool

    init(mayQuitOnLastWindow: @escaping (NSRunningApplication) -> Bool) {
        self.mayQuitOnLastWindow = mayQuitOnLastWindow
    }

    static func canQuit(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && app.activationPolicy == .regular && app.processIdentifier != getpid() &&
            app.bundleIdentifier != "com.apple.finder" && app.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    /// AXWindows is the application's inventory, including minimized windows.
    /// WindowServer provides an independent veto for another *visible* window.
    /// Its all-windows list also contains backing stores retained after close.
    private func hasNoVisibleWindow(of app: NSRunningApplication) -> Bool {
        let visible = SystemWindow.visible()
        return !visible.isEmpty && !visible.contains {
            $0.pid == app.processIdentifier && $0.layer == 0
        }
    }

    private func windows(of app: NSRunningApplication) -> [AXUIElement]? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.15)
        return AX.value(ax, kAXWindowsAttribute) as? [AXUIElement]
    }

    func close(_ target: WindowTarget) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == target.pid,
              app.processIdentifier != getpid(), !app.isTerminated,
              let button = target.button(for: 0), let frame = target.buttonFrame(for: 0),
              target.ownsTopmostFrame(frame), target.isCurrent() else { return false }
        let request = Request(app: app, window: target.window, id: target.id)
        let wasLast = Self.canQuit(app) && mayQuitOnLastWindow(app) && windows(of: app).map {
            $0.count == 1 && AX.same($0[0], target.window)
        } == true
        pending[target.pid] = nil
        // Press the retained native close button itself. A later focus change
        // cannot redirect it to a different window as a keyboard shortcut could.
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        // An app may tear down the control before acknowledging AXPress.
        // Never send a second press. Only an independently verified empty
        // inventory can turn this attempt into a request to quit.
        guard result == .success || result == .cannotComplete else { return false }
        if wasLast {
            pending[target.pid] = request
            check(request, final: false)
            verifyClosure(request)
        }
        return result == .success || wasLast
    }

    private func verifyClosure(_ request: Request) {
        let survey = UUID()
        request.survey = survey
        // Window destruction, AXWindows, and the composited close animation
        // may settle in different orders. Only the end of this sequence can
        // expire a still-unconfirmed close.
        for delay in [0.12, 0.45, 1.2, 2.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard request.survey == survey else { return }
                self?.check(request, final: delay == 5.0)
            }
        }
    }

    // Edge can handle the red click on its native title bar. Follow the actual
    // destruction of a known last browser window even when Trio did not handle
    // that click. Losing focus, hiding, and minimizing are not closes.
    func observeBrowserWindow(_ target: WindowTarget) {
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == "com.microsoft.edgemac",
              Self.canQuit(app), mayQuitOnLastWindow(app), target.button(for: 0) != nil,
              AX.string(target.window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              let windows = windows(of: app), windows.count == 1, AX.same(windows[0], target.window) else {
            observedEdgeWindows[target.pid] = nil
            return
        }
        if let previous = observedEdgeWindows[target.pid], AX.same(previous.window, target.window) { return }
        observedEdgeWindows[target.pid] = Request(app: app, window: target.window, id: target.id)
    }

    func browserWindowMayHaveClosed(in pid: pid_t) {
        guard pending[pid] == nil, let request = observedEdgeWindows[pid],
              !request.app.isHidden, !request.app.isTerminated, mayQuitOnLastWindow(request.app),
              let inventory = windows(of: request.app), inventory.isEmpty,
              SystemWindow.noLongerExists(request.id) else { return }
        observedEdgeWindows[pid] = nil
        pending[pid] = request
        verifyClosure(request)
        check(request, final: false)
    }

    func windowDestroyed(_ element: AXUIElement) {
        if let request = pending.values.first(where: { AX.same(element, $0.window) }) {
            if !request.quitRequested { verifyClosure(request) }
            return
        }
        guard let request = observedEdgeWindows.values.first(where: { AX.same(element, $0.window) }) else { return }
        let pid = request.app.processIdentifier
        observedEdgeWindows[pid] = nil
        pending[pid] = request
        verifyClosure(request)
        check(request, final: false)
    }

    func windowOpened(_ element: AXUIElement, in pid: pid_t) {
        if let anchor = observedEdgeWindows[pid], !AX.same(element, anchor.window) { observedEdgeWindows[pid] = nil }
        if let request = pending[pid], !AX.same(element, request.window) { pending[pid] = nil }
    }

    func forget(_ pid: pid_t) {
        pending[pid] = nil
        observedEdgeWindows[pid] = nil
    }

    func reset() {
        pending.removeAll()
        observedEdgeWindows.removeAll()
    }

    private func check(_ request: Request, final: Bool) {
        let app = request.app, pid = app.processIdentifier
        guard pending[pid]?.token == request.token else { return }
        guard Self.canQuit(app), mayQuitOnLastWindow(app), let remaining = windows(of: app) else {
            if final { forget(pid) }
            return
        }
        if remaining.contains(where: { !AX.same($0, request.window) }) {
            // A surviving window, including a minimized one, owns its own
            // future close. This click must never quit on its behalf.
            forget(pid)
            return
        }
        if remaining.isEmpty && hasNoVisibleWindow(of: app) {
            if request.quitRequested {
                guard NSRunningApplication(processIdentifier: pid) == app else { forget(pid); return }
                forget(pid)
                _ = app.forceTerminate()
                return
            }
            request.quitRequested = true
            // The native window has closed. Give a responsive app the normal
            // quit request immediately. The next confirmed empty inventory
            // enforces it if the same instance has stayed alive.
            _ = app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.check(request, final: final)
            }
        } else if final {
            // Keep waiting only for this exact window's save sheet.
            let waitingForSave = remaining.count == 1 && AX.same(remaining[0], request.window) &&
                (AX.value(request.window, kAXChildrenAttribute) as? [AXUIElement])?.contains {
                    AX.string($0, kAXRoleAttribute) == kAXSheetRole
                } == true
            if !waitingForSave { forget(pid) }
        }
    }
}
