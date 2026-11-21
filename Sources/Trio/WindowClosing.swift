import AppKit
import ApplicationServices

/// Correlates a close with the original application instance and window.
@MainActor final class WindowClosing {
    private final class Request {
        let app: NSRunningApplication
        let window: AXUIElement
        let id: CGWindowID
        let token = UUID()
        var survey = UUID()
        var requireMissingWindowID = false
        var quitRequested = false

        init(app: NSRunningApplication, window: AXUIElement, id: CGWindowID) {
            self.app = app
            self.window = window
            self.id = id
        }
    }
    private var pending: [pid_t: Request] = [:]
    private var observedWindows: [pid_t: Request] = [:]
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
        let inventory = windows(of: app)
        let lastConfirmed = inventory.map { $0.count == 1 && AX.same($0[0], target.window) } ?? false
        let canFollow = Self.canQuit(app) && mayQuitOnLastWindow(app) &&
            (lastConfirmed || inventory?.isEmpty != false)
        request.requireMissingWindowID = !lastConfirmed
        pending[target.pid] = nil
        // Press the retained native close button itself. A later focus change
        // cannot redirect it to a different window as a keyboard shortcut could.
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        // An app may tear down the control before acknowledging AXPress.
        // Never send a second press. Only an independently verified empty
        // inventory can turn this attempt into a request to quit.
        guard result == .success || result == .cannotComplete else { return false }
        if canFollow { begin(request) }
        return result == .success || canFollow
    }

    private func begin(_ request: Request) {
        pending[request.app.processIdentifier] = request
        verifyClosure(request)
        check(request, final: false)
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

    // These apps may close a native window without delivering AXDestroyed.
    // Track the specific last standard window, independently of toolbars or versions.
    static func observesNativeClosure(of app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.microsoft.edgemac" || app.bundleIdentifier == "com.google.antigravity"
    }

    func observeBrowserWindow(_ target: WindowTarget) {
        guard let app = NSRunningApplication(processIdentifier: target.pid), Self.observesNativeClosure(of: app),
              target.button(for: 0) != nil else { return }
        observeNativeWindow(app: app, window: target.window, id: target.id)
    }

    func observeNativeWindow(app: NSRunningApplication, window: AXUIElement, id: CGWindowID) {
        guard Self.canQuit(app), mayQuitOnLastWindow(app),
              AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              let inventory = windows(of: app) else { return }
        let pid = app.processIdentifier
        guard inventory.count == 1, AX.same(inventory[0], window) else {
            if !inventory.isEmpty { observedWindows[pid] = nil }
            return
        }
        if let prior = observedWindows[pid], prior.id == id, AX.same(prior.window, window) { return }
        let request = Request(app: app, window: window, id: id)
        request.requireMissingWindowID = true
        observedWindows[pid] = request
    }

    func browserWindowMayHaveClosed(in pid: pid_t) {
        guard let anchor = observedWindows[pid], !anchor.app.isHidden,
              Self.canQuit(anchor.app), mayQuitOnLastWindow(anchor.app) else { return }
        if let request = pending[pid] {
            if !request.quitRequested { check(request, final: false) }
            return
        }
        // A single focus/destruction event can precede both the AX window
        // list update and WindowServer removing the ID. Arm bounded retries
        // now, even when the window still exists on this first check.
        begin(anchor)
    }

    func windowDestroyed(_ element: AXUIElement) {
        if let request = pending.values.first(where: { AX.same(element, $0.window) }) {
            if !request.quitRequested { verifyClosure(request); check(request, final: false) }
        } else if let anchor = observedWindows.values.first(where: { AX.same(element, $0.window) }) {
            browserWindowMayHaveClosed(in: anchor.app.processIdentifier)
        }
    }

    func windowOpened(_ element: AXUIElement, in pid: pid_t) {
        if let anchor = observedWindows[pid], !AX.same(element, anchor.window) { observedWindows[pid] = nil }
        if let request = pending[pid], !AX.same(element, request.window) { pending[pid] = nil }
    }

    func forget(_ pid: pid_t) {
        pending[pid] = nil
        observedWindows[pid] = nil
    }

    func reset() {
        pending.removeAll()
        observedWindows.removeAll()
    }

    private func check(_ request: Request, final: Bool) {
        let app = request.app, pid = app.processIdentifier
        guard pending[pid]?.token == request.token else { return }
        guard Self.canQuit(app), mayQuitOnLastWindow(app), !app.isHidden else { forget(pid); return }
        guard let remaining = windows(of: app) else {
            if final { pending[pid] = nil }
            return
        }
        if remaining.contains(where: { !AX.same($0, request.window) }) {
            // A surviving window, including a minimized one, owns its own
            // future close. This click must never quit on its behalf.
            forget(pid)
            return
        }
        if remaining.isEmpty && (!request.requireMissingWindowID || SystemWindow.noLongerExists(request.id)) &&
            hasNoVisibleWindow(of: app) {
            guard NSRunningApplication(processIdentifier: pid) == app else { forget(pid); return }
            // Force Quit only this exact instance, after the window close
            // completed and both inventories confirmed there are no survivors.
            request.quitRequested = true
            _ = app.forceTerminate()
            if app.isTerminated || final { forget(pid) }
        } else if final {
            // Keep waiting only for this exact window's save sheet.
            let waitingForSave = remaining.count == 1 && AX.same(remaining[0], request.window) &&
                (AX.value(request.window, kAXChildrenAttribute) as? [AXUIElement])?.contains {
                    AX.string($0, kAXRoleAttribute) == kAXSheetRole
                } == true
            if !waitingForSave { pending[pid] = nil }
        }
    }
}
