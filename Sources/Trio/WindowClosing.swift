import AppKit
import ApplicationServices
import Darwin

/// Correlates a close with the original application instance and window.
@MainActor final class WindowClosing {
    private final class Request {
        let app: NSRunningApplication
        let window: AXUIElement
        let processBirth: UInt64?
        let id: CGWindowID
        let token = UUID()
        var survey = UUID()
        var transientSurfaces: [AXUIElement] = []
        var requireMissingWindowID = false
        var quitRequested = false
        var forceCanEscalate = false

        init(app: NSRunningApplication, window: AXUIElement, id: CGWindowID, processBirth: UInt64?) {
            self.app = app
            self.processBirth = processBirth
            self.window = window
            self.id = id
        }
    }
    private var pending: [pid_t: Request] = [:]
    private var observedWindows: [pid_t: Request] = [:]
    private let mayQuitOnLastWindow: (NSRunningApplication) -> Bool

    private let processBirth: (pid_t) -> UInt64?
    private let forceStalledProcess: (pid_t) -> Bool
    private let diagnostics = CommandLine.arguments.contains("--diagnostics")

    private func trace(_ message: @autoclosure () -> String) {
        if diagnostics { FileHandle.standardError.write(Data(("[Trio close] " + message() + "\n").utf8)) }
    }

    nonisolated static func kernelBirth(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let bytes = Int32(MemoryLayout.size(ofValue: info))
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, bytes) == bytes,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    init(processBirth: @escaping (pid_t) -> UInt64? = WindowClosing.kernelBirth,
         forceStalledProcess: @escaping (pid_t) -> Bool = { Darwin.kill($0, SIGKILL) == 0 },
         mayQuitOnLastWindow: @escaping (NSRunningApplication) -> Bool) {
        self.processBirth = processBirth
        self.forceStalledProcess = forceStalledProcess
        self.mayQuitOnLastWindow = mayQuitOnLastWindow
    }

    static func canQuit(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && app.activationPolicy == .regular && app.processIdentifier != getpid() &&
            app.bundleIdentifier != "com.apple.finder" && app.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private func windows(of app: NSRunningApplication) -> [AXUIElement]? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.15)
        return AX.value(ax, kAXWindowsAttribute) as? [AXUIElement]
    }

    private func verifiedLastOwner(_ target: WindowTarget) -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == target.pid,
              Self.canQuit(app), !app.isHidden, mayQuitOnLastWindow(app),
              AX.string(target.window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              let inventory = windows(of: app), inventory.count == 1,
              AX.same(inventory[0], target.window), !AX.flag(target.window, kAXMinimizedAttribute)
        else { return nil }
        return app
    }

    func shouldForwardLastClose(_ target: WindowTarget) -> Bool {
        verifiedLastOwner(target) != nil
    }

    /// Captures the exact window before the native mouse-down. The caller
    /// starts the survey only after both events have been posted successfully.
    func authorizeForwardedLastClose(_ target: WindowTarget) -> (() -> Void)? {
        guard let app = verifiedLastOwner(target) else { return nil }
        let request = Request(app: app, window: target.window, id: target.id, processBirth: processBirth(target.pid))
        return { [weak self] in
            self?.trace("native click posted pid=\(target.pid) window=\(target.id)")
            self?.begin(request)
        }
    }

    /// Chromium exposes some toolbar popups as nonmodal AXDialog windows.
    /// Keep observing their owner, but never quit while they remain in AXWindows.
    private func isTransientSurface(_ window: AXUIElement, in pid: pid_t, previouslyProven: [AXUIElement] = []) -> Bool {
        guard !AX.flag(window, kAXMinimizedAttribute), !AX.flag(window, kAXModalAttribute),
              let subrole = AX.string(window, kAXSubroleAttribute),
              subrole == kAXUnknownSubrole || subrole == kAXDialogSubrole,
              [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
                .allSatisfy({ AX.value(window, $0) == nil }) else { return false }
        return subrole == kAXUnknownSubrole || previouslyProven.contains { AX.same($0, window) } ||
            SystemWindow.isFloatingSurface(window, ownedBy: pid)
    }

    func close(_ target: WindowTarget) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == target.pid,
              app.processIdentifier != getpid(), !app.isTerminated,
              let button = target.button(for: 0), let frame = target.buttonFrame(for: 0),
              target.ownsTopmostFrame(frame), target.isCurrent() else { return false }
        let request = Request(app: app, window: target.window, id: target.id, processBirth: processBirth(target.pid))
        let inventory = windows(of: app)
        let lastConfirmed = inventory.map { $0.count == 1 && AX.same($0[0], target.window) } ?? false
        let others = inventory?.filter { !AX.same($0, target.window) } ?? []
        request.transientSurfaces = others.filter { isTransientSurface($0, in: target.pid) }
        let hasSibling = others.count != request.transientSurfaces.count
        let canFollow = Self.canQuit(app) && mayQuitOnLastWindow(app) && !hasSibling
        request.requireMissingWindowID = !lastConfirmed
        pending[target.pid] = nil
        // Press the retained native close button itself. A later focus change
        // cannot redirect it to a different window as a keyboard shortcut could.
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        trace("targeted close pid=\(target.pid) window=\(target.id) initialCount=\(inventory?.count ?? -1) follow=\(canFollow) result=\(result.rawValue)")
        // An app may tear down the control before acknowledging AXPress.
        // Never send a second press. Only an independently verified empty
        // inventory can turn this attempt into a request to quit.
        if canFollow {
            if result != .success { request.requireMissingWindowID = true }
            begin(request)
        }
        return result == .success || (canFollow && result == .cannotComplete)
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
        guard inventory.contains(where: { AX.same($0, window) }) else { return }
        if inventory.contains(where: { !AX.same($0, window) && !isTransientSurface($0, in: pid) }) {
            observedWindows[pid] = nil
            return
        }
        if let prior = observedWindows[pid], prior.id == id, AX.same(prior.window, window) { return }
        let request = Request(app: app, window: window, id: id, processBirth: processBirth(pid))
        request.transientSurfaces = inventory.filter { !AX.same($0, window) }
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
        guard let request = pending[pid] ?? observedWindows[pid],
              !AX.same(element, request.window),
              let inventory = windows(of: request.app),
              inventory.contains(where: { AX.same($0, element) }) else { return }
        if request.transientSurfaces.contains(where: { AX.same($0, element) }) { return }
        if isTransientSurface(element, in: pid) {
            request.transientSurfaces.append(element)
            return
        }
        trace("new window cancels close pid=\(pid)")
        forget(pid)
    }

    func forget(_ pid: pid_t) {
        pending[pid] = nil
        observedWindows[pid] = nil
    }

    func reset() {
        pending.removeAll()
        observedWindows.removeAll()
    }

    private func sameProcess(_ request: Request) -> Bool {
        let app = request.app, pid = app.processIdentifier
        // AppKit does not always supply a launch date. The kernel birth time
        // also distinguishes a recycled PID when Launch Services lags behind.
        if let original = request.processBirth {
            return processBirth(pid) == original
        }
        guard let live = NSRunningApplication(processIdentifier: pid), live == app,
              let birth = app.launchDate else { return false }
        return live.launchDate == birth
    }

    private func check(_ request: Request, final: Bool) {
        let app = request.app, pid = app.processIdentifier
        guard pending[pid]?.token == request.token else { return }
        guard Self.canQuit(app), mayQuitOnLastWindow(app), !app.isHidden else {
            trace("survey stopped pid=\(pid) terminated=\(app.isTerminated) hidden=\(app.isHidden) policy=\(app.activationPolicy.rawValue)")
            forget(pid); return
        }
        guard let remaining = windows(of: app) else {
            if final { pending[pid] = nil }
            return
        }
        if remaining.contains(where: { !AX.same($0, request.window) && !isTransientSurface($0, in: pid, previouslyProven: request.transientSurfaces) }) {
            trace("surviving window cancels close pid=\(pid) count=\(remaining.count)")
            // A surviving window, including a minimized one, owns its own
            // future close. This click must never quit on its behalf.
            forget(pid)
            return
        }
        let targetGone = remaining.isEmpty && (!request.requireMissingWindowID || SystemWindow.noLongerExists(request.id))
        let windowless = targetGone && SystemWindow.hasNoVisibleWindow(ownedBy: pid)
        trace("survey pid=\(pid) count=\(remaining.count) gone=\(targetGone) windowless=\(windowless)")
        if windowless {
            guard sameProcess(request) else {
                trace("process identity unavailable pid=\(pid)")
                forget(pid); return
            }
            if request.quitRequested {
                guard request.forceCanEscalate else { return }
                // A force request may return before the process exits. Never
                // escalate against a replacement PID or a newly opened window.
                let accepted = forceStalledProcess(pid)
                trace("confirmed windowless after force pid=\(pid) signalAccepted=\(accepted)")
                if accepted || final { forget(pid) }
                return
            }
            request.quitRequested = true
            let accepted = app.forceTerminate()
            trace("confirmed windowless pid=\(pid) window=\(request.id) forceAccepted=\(accepted)")
            if app.isTerminated { forget(pid); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                request.forceCanEscalate = true
                self?.check(request, final: final)
            }
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
