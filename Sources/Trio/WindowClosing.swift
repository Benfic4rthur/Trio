import AppKit
import ApplicationServices

/// Only a close initiated by Trio can authorize a subsequent last-window quit.
@MainActor final class WindowClosing {
    private struct Request {
        let app: NSRunningApplication
        let window: AXUIElement
        let id: CGWindowID
        let token = UUID()
    }
    private var pending: [pid_t: Request] = [:]
    private var awaitingExit: [pid_t: UUID] = [:]
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
    private func hasNoVisibleWindow(of app: NSRunningApplication, except allowedID: CGWindowID? = nil) -> Bool {
        let visible = SystemWindow.visible()
        return !visible.isEmpty && !visible.contains {
            $0.pid == app.processIdentifier && $0.layer == 0 && $0.id != allowedID
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
        } == true && hasNoVisibleWindow(of: app, except: target.id)
        forget(target.pid)
        // Press the retained native close button itself. A later focus change
        // cannot redirect it to a different window as a keyboard shortcut could.
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
        if wasLast {
            pending[target.pid] = request
            // Delayed AX list updates are common. A save sheet may remain open
            // longer; its actual window destruction is observed separately.
            for delay in [0.12, 0.45, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.check(request, final: delay == 1.2)
                }
            }
        }
        return true
    }

    func windowDestroyed(_ element: AXUIElement) {
        for request in pending.values where AX.same(element, request.window) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.check(request, final: true)
            }
        }
    }

    func windowOpened(in pid: pid_t) { awaitingExit[pid] = nil }

    func forget(_ pid: pid_t) {
        pending[pid] = nil
        awaitingExit[pid] = nil
    }

    func reset() {
        pending.removeAll()
        awaitingExit.removeAll()
    }

    private func check(_ request: Request, final: Bool) {
        let app = request.app, pid = app.processIdentifier
        guard pending[pid]?.token == request.token else { return }
        guard Self.canQuit(app), mayQuitOnLastWindow(app), let remaining = windows(of: app) else {
            if final { forget(pid) }
            return
        }
        if remaining.isEmpty && hasNoVisibleWindow(of: app) {
            forget(pid)
            awaitingExit[pid] = request.token
            _ = app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.awaitingExit[pid] == request.token else { return }
                self.awaitingExit[pid] = nil
                // Use the original running instance. Revalidate the exception
                // list and window inventory after the grace period.
                guard Self.canQuit(app), self.mayQuitOnLastWindow(app),
                      NSRunningApplication(processIdentifier: pid) == app,
                      self.windows(of: app)?.isEmpty == true, self.hasNoVisibleWindow(of: app) else { return }
                _ = app.forceTerminate()
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
