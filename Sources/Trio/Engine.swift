import AppKit
import ApplicationServices
import TrioCore
import notify

private func trioAXEvent(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let engine = Unmanaged<TrioEngine>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { engine.handle(element, notification: name as String) }
}

@MainActor final class TrioEngine: NSObject {
    private let settings: SettingsStore
    private let onStatus: (String) -> Void
    private let onOpen: () -> Void
    private let panel: TrioPanel
    private let controls = TrioControlsView(frame: .zero)
    private let arrangementPanel = ArrangementPanel()
    private lazy var closing = WindowClosing { [weak self] app in
        guard let self, self.running, !self.sessionSuspended, self.settings.enabled,
              let identifier = app.bundleIdentifier else { return false }
        return !self.settings.quitExcludedBundleIDs.contains(identifier)
    }
    private var target: WindowTarget?
    private var observers: [pid_t: AXObserver] = [:]
    private var watchedWindows: [pid_t: [AXUIElement]] = [:]
    private var watchedControls: [pid_t: [(window: AXUIElement, buttons: [AXUIElement])]] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var pending: DispatchWorkItem?
    private var greenMenu: DispatchWorkItem?
    private var forwarding = false
    private var running = false
    private var sessionSuspended = false
    private var sessionNotifyTokens: [Int32] = []
    private var resumeWorks: [DispatchWorkItem] = []
    private var resumeMouseMonitor: Any?
    private var appliedScale: Double?
    private var drawingNeedsControlGeometry = false
    private var needsFullLayoutRefresh = false
    private var dragFollowWork: DispatchWorkItem?
    private var geometrySettleWork: DispatchWorkItem?
    private var lastGeometryFollow: TimeInterval = 0
    private var manualGeometryInteraction: (pid: pid_t, id: CGWindowID, window: AXUIElement)?
    private var pendingNativeDrag: (pid: pid_t, id: CGWindowID, point: CGPoint)?
    private let windowAnimator = WindowAnimator()
    private var animatingWindow: AXUIElement?
    private var animationToken: UUID?
    private var restore: [(pid: pid_t, window: AXUIElement, original: CGRect, applied: CGRect)] = []
    private final class AutoMaximizeRequest {
        let window: AXUIElement
        let application: NSRunningApplication
        let expiresAt: TimeInterval
        var stability: AutoMaximizeStability
        var nextCheck: TimeInterval?
        init(window: AXUIElement, application: NSRunningApplication, now: TimeInterval) {
            self.window = window; self.application = application
            expiresAt = now + 1.6
            stability = AutoMaximizeStability(startedAt: now)
            nextCheck = now + 0.18
        }
    }
    // Completed entries remain until destruction/termination, so late launch
    // surveys cannot repeat an automatic change after a manual restoration.
    private var autoMaximizeRequests: [AutoMaximizeRequest] = []
    private var autoMaximizeWork: DispatchWorkItem?
    private var autoMaximizeScheduledToken: UUID?
    private var autoMaximizeGeneration = UUID()

    init(settings: SettingsStore, onStatus: @escaping (String) -> Void, onOpen: @escaping () -> Void) {
        self.settings = settings; self.onStatus = onStatus; self.onOpen = onOpen
        panel = TrioPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        // A normal-level foreign window is raised again by its own clicks.
        // Keep this nonactivating panel above ordinary app windows; Workspace
        // and AX identity tracking remove it immediately on a real transition.
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenNone]
        panel.isExcludedFromWindowsMenu = true; panel.isReleasedWhenClosed = false
        let surface = NSView(frame: .zero)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12; surface.layer?.cornerCurve = .continuous; surface.layer?.masksToBounds = true
        // Concentric opaque lights themselves hide the original circles.
        // The surrounding hit region needs virtually no visual background.
        surface.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.015).cgColor
        controls.autoresizingMask = [.width, .height]
        surface.addSubview(controls)
        panel.contentView = surface
        controls.targetWindow = { [weak self] in self?.target?.id }
        controls.onAction = { [weak self] index in self?.perform(index) }
        controls.onContext = { [weak self] in self?.contextMenu() }
        controls.onGreenHover = { [weak self] in self?.scheduleGreenMenu() }
        controls.onHoverChange = { [weak self] index in
            if let index, index != 2 { self?.arrangementPanel.hide() }
        }
        arrangementPanel.onSelect = { [weak self] tag in
            let item = NSMenuItem(); item.tag = tag; self?.arrange(item)
        }
        arrangementPanel.onOpen = { [weak self] in self?.arrangementPanel.hide(); self?.onOpen() }
        arrangementPanel.onDismiss = { [weak self] in
            guard let self else { return }
            self.controls.holdGreenHover = false
            if self.controls.hover == 2 { self.controls.hover = nil }
        }
    }

    func start() {
        guard !running else { return }; running = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.12)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendSession() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeSession() }
            })
        }
        // Both Darwin notification names are public constants in CGSession.h.
        // No private screen-lock dictionary keys or undocumented notifications.
        for name in [kCGNotifyGUIConsoleSessionChanged, kCGNotifyGUISessionUserChanged] {
            var token: Int32 = 0
            if notify_register_dispatch(name, &token, .main, { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeSession() }
            }) == NOTIFY_STATUS_OK { sessionNotifyTokens.append(token) }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.sessionSuspended {
                        if NSWorkspace.shared.frontmostApplication?.activationPolicy == .regular { self.resumeSession() }
                        return
                    }
                    let changedApp = self.target?.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier
                    self.diagnostic("tracking workspace=\(name.rawValue) changedPID=\(changedApp)")
                    // Spaces and wake invalidate the drawing even when the
                    // same app/window is reported during the transition.
                    if name == NSWorkspace.activeSpaceDidChangeNotification || changedApp { self.hide() }
                    self.scheduleRefresh(after: 0.04)
                }
            })
        }
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let generation = self.autoMaximizeGeneration
                for delay in [0.4, 0.9] {
                    DispatchQueue.main.asyncAfter(deadline: .now()+delay) { [weak self] in
                        guard let self, self.running, !app.isTerminated else { return }
                        self.observe(app)
                        if self.autoMaximizeGeneration == generation, self.settings.enabled && self.settings.autoMaximizeNewWindows,
                           let windows = AX.value(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] {
                            for window in windows { self.maximizeNew(window, pid: app.processIdentifier) }
                        }
                        self.scheduleRefresh()
                    }
                }
            }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.sessionSuspended,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.closing.browserWindowMayHaveClosed(in: app.processIdentifier)
            }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.closing.forget(app.processIdentifier)
                self?.removeObserver(app.processIdentifier)
                if self?.target?.pid == app.processIdentifier { self?.hide() }
                self?.scheduleRefresh()
            }
        })
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSApplication.didChangeScreenParametersNotification ||
                        self?.target?.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier { self?.hide() }
                    self?.scheduleRefresh()
                }
            })
        }
        // A verified title-bar/edge press only arms drag detection. A stationary
        // click must keep the drawing visible; hide only once dragging starts.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.forwarding, self.animatingWindow == nil else { return }
                if event.type == .leftMouseDown {
                    self.noteNativeClosePress(event)
                    self.pendingNativeDrag = nil
                    if self.target == nil || !self.panel.isVisible {
                        self.scheduleRefresh(after: 0.02)
                    } else { self.armNativeGeometryDrag(event) }
                }
                else if event.type == .leftMouseDragged {
                    self.beginArmedNativeDrag(event)
                    self.scheduleDragFollow()
                }
                else {
                    self.pendingNativeDrag = nil
                    self.dragFollowWork?.cancel(); self.dragFollowWork = nil
                    let wasManual = self.manualGeometryInteraction != nil
                    let changed = self.checkDraggedGeometry()
                    self.manualGeometryInteraction = nil
                    if wasManual || changed { self.settleGeometry(after: 0.07) }
                    else {
                        // A toolbar can move its native lights without changing
                        // the outer window frame. Verify those three rectangles,
                        // keeping an unchanged drawing intact on content clicks.
                        self.drawingNeedsControlGeometry = true
                        self.scheduleRefresh(after: 0.015)
                    }
                }
            }
        }
        refresh()
    }
    func stop() {
        closing.reset()
        running = false; pending?.cancel(); greenMenu?.cancel(); hide()
        cancelAutoMaximize(clearHistory: true)
        cancelResumeWork()
        for token in sessionNotifyTokens { notify_cancel(token) }
        sessionNotifyTokens.removeAll()
        windowAnimator.cancel(); animatingWindow = nil
        manualGeometryInteraction = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token); NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        for pid in Array(observers.keys) { removeObserver(pid) }
    }
    private func removeObserver(_ pid: pid_t, discardRestore: Bool = true) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        watchedWindows[pid] = nil
        watchedControls[pid] = nil
        if discardRestore {
            restore.removeAll { $0.pid == pid }
            autoMaximizeRequests.removeAll { $0.application.processIdentifier == pid }
            scheduleAutoMaximize()
        }
    }
    private func cancelResumeWork() {
        resumeWorks.forEach { $0.cancel() }; resumeWorks.removeAll()
        if let resumeMouseMonitor { NSEvent.removeMonitor(resumeMouseMonitor) }
        resumeMouseMonitor = nil
    }
    private func suspendSession() {
        guard running else { return }
        sessionSuspended = true
        closing.reset()
        cancelAutoMaximize(clearHistory: false)
        cancelResumeWork()
        pending?.cancel(); manualGeometryInteraction = nil
        windowAnimator.cancel(); animatingWindow = nil; animationToken = nil
        hide()
        diagnostic("session suspended; drawing discarded")
    }
    private func resumeSession() {
        guard running else { return }
        cancelResumeWork()
        sessionSuspended = false
        manualGeometryInteraction = nil
        hide()
        // AX handles/subscriptions and the window backing store may have been
        // recreated while locked. Keep the user's restore geometry/preferences.
        for pid in Array(observers.keys) { removeObserver(pid, discardRestore: false) }
        for delay in [0.04, 0.25, 0.75, 1.5, 3.0] {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.running, !self.sessionSuspended else { return }
                self.refresh()
            }
            resumeWorks.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
        }
        // One input-triggered retry covers a delayed unlock after the wake
        // burst. It removes itself on the first movement, never polling idle.
        resumeMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.sessionSuspended,
                      NSWorkspace.shared.frontmostApplication?.activationPolicy == .regular else { return }
                if let monitor = self.resumeMouseMonitor { NSEvent.removeMonitor(monitor) }
                self.resumeMouseMonitor = nil
                self.scheduleRefresh(after: 0.015)
            }
        }
        diagnostic("session resume; bounded fresh survey scheduled")
    }
    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard running, AXIsProcessTrusted(), app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, trioAXEvent, &observer) == .success, let observer else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var subscribed = false
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                     kAXFocusedUIElementChangedNotification, kAXLayoutChangedNotification] {
            if AXObserverAddNotification(observer, axApp, name as CFString, context) == .success { subscribed = true }
        }
        guard subscribed else { return }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        if let windows = AX.value(axApp, kAXWindowsAttribute) as? [AXUIElement] {
            for window in windows { watch(window, pid: pid) }
        }
    }
    private func watch(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid], !(watchedWindows[pid] ?? []).contains(where: { AX.same($0, window) }) else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification, kAXLayoutChangedNotification] {
            _ = AXObserverAddNotification(observer, window, name as CFString, context)
        }
        watchedWindows[pid, default: []].append(window)
    }
    private func watchControls(of candidate: WindowTarget) {
        guard let observer = observers[candidate.pid] else { return }
        var groups = watchedControls[candidate.pid] ?? []
        let names = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification]
        if let index = groups.firstIndex(where: { AX.same($0.window, candidate.window) }) {
            if groups[index].buttons.count == candidate.buttons.count && zip(groups[index].buttons, candidate.buttons).allSatisfy({ AX.same($0.0, $0.1) }) { return }
            for button in groups.remove(at: index).buttons {
                for name in names { AXObserverRemoveNotification(observer, button, name as CFString) }
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for button in candidate.buttons {
            for name in names { _ = AXObserverAddNotification(observer, button, name as CFString, context) }
        }
        groups.append((candidate.window, candidate.buttons))
        watchedControls[candidate.pid] = groups
    }
    fileprivate func handle(_ element: AXUIElement, notification: String) {
        guard running, !sessionSuspended else { return }
        let eventPID = AX.pid(element)
        let affectsTarget = target.map { AX.same($0.window, element) } ?? false
        let affectsControl = target?.buttons.contains(where: { AX.same($0, element) }) ?? false
        if eventPID == target?.pid { drawingNeedsControlGeometry = true }
        if affectsTarget && notification == kAXLayoutChangedNotification {
            needsFullLayoutRefresh = true
            scheduleRefresh(after: 0.06)
        }
        diagnostic("tracking AX=\(notification) eventPID=\(eventPID) targetPID=\(target?.pid ?? 0) targetID=\(target?.id ?? 0) targetElement=\(affectsTarget)")
        if notification == kAXWindowCreatedNotification {
            closing.windowOpened(element, in: eventPID)
            let pid = eventPID
            watch(element, pid: pid)
            if settings.enabled && settings.autoMaximizeNewWindows {
                maximizeNew(element, pid: pid)
            }
        }
        if notification == kAXUIElementDestroyedNotification {
            closing.windowDestroyed(element)
            restore.removeAll { AX.same($0.window, element) }
            autoMaximizeRequests.removeAll { AX.same($0.window, element) }
            scheduleAutoMaximize()
            let pid = AX.pid(element)
            watchedWindows[pid]?.removeAll { AX.same($0, element) }
            watchedControls[pid]?.removeAll { AX.same($0.window, element) }
        }
        if notification == kAXMainWindowChangedNotification || notification == kAXFocusedWindowChangedNotification {
            closing.browserWindowMayHaveClosed(in: eventPID)
        }
        guard !forwarding else { return }
        if notification == kAXUIElementDestroyedNotification && affectsControl {
            watchedControls[eventPID]?.removeAll { $0.buttons.contains(where: { AX.same($0, element) }) }
            hide(); scheduleRefresh(after: 0.04); return
        }
        // Streaming web content may emit many nested layout notifications.
        // Coalesce them; native window/control changes remain immediate.
        if notification == kAXLayoutChangedNotification && !affectsTarget && !affectsControl {
            scheduleRefresh(after: 0.06); return
        }
        if let animatingWindow, AX.same(element, animatingWindow),
           notification == kAXMovedNotification || notification == kAXResizedNotification { return }
        if affectsTarget && (notification == kAXUIElementDestroyedNotification || notification == kAXWindowMiniaturizedNotification) {
            diagnostic("tracking hide=target-destroyed-or-minimized")
            hide(); scheduleRefresh(after: 0.09); return
        }
        if affectsTarget && (notification == kAXMovedNotification || notification == kAXResizedNotification) {
            if let current = target {
                let visible = SystemWindow.visible().first { $0.id == current.id && $0.pid == current.pid && $0.layer == 0 }
                let actual = AX.rect(element)
                if visible.map({ !SystemWindow.close($0.bounds, current.frame, tolerance: 0.1) }) == true ||
                    actual.map({ !SystemWindow.close($0, current.frame, tolerance: 0.1) }) == true {
                    beginManualGeometry(current)
                    settleGeometry(after: 0.07)
                    return
                }
                drawingNeedsControlGeometry = true
                settleGeometry(after: 0.07)
            }
        }
        if let target, panel.isVisible {
            switch drawingStability(of: target) {
            case .stable:
                diagnostic("tracking keep=focused-window-and-frame-stable")
                return
            case .transient(let reason):
                diagnostic("tracking keep-transient=\(reason)")
                scheduleRefresh(after: 0.04, attempt: 1)
                return
            case .changed(let reason):
                diagnostic("tracking hide=\(reason)")
                hide()
            }
        }
        scheduleRefresh(after: notification == kAXResizedNotification || notification == kAXMovedNotification ? 0.09 : 0.04)
    }
    private func scheduleRefresh(after seconds: Double = 0.05, attempt: Int = 0) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(attempt: attempt) }; pending = work
        DispatchQueue.main.asyncAfter(deadline: .now()+seconds, execute: work)
    }
    private func hide() {
        if let target { closing.browserWindowMayHaveClosed(in: target.pid) }
        pendingNativeDrag = nil
        dragFollowWork?.cancel(); dragFollowWork = nil
        geometrySettleWork?.cancel(); geometrySettleWork = nil
        arrangementPanel.hide()
        panel.ignoresMouseEvents = true
        panel.setAccessibilityHidden(true)
        controls.setAccessibilityHidden(true)
        drawingNeedsControlGeometry = false
        needsFullLayoutRefresh = false
        panel.orderOut(nil); target = nil; greenMenu?.cancel(); controls.resetHover()
    }

    private func scheduleDragFollow() {
        guard target != nil, panel.isVisible, dragFollowWork == nil else { return }
        let delay = max(0, 1.0/60 - (ProcessInfo.processInfo.systemUptime-lastGeometryFollow))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dragFollowWork = nil
            self.lastGeometryFollow = ProcessInfo.processInfo.systemUptime
            self.checkDraggedGeometry()
        }
        dragFollowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
    }

    /// Native title bars can receive a red click before the overlay or its
    /// AX observer is ready. Watch that original click without replaying it.
    private func noteNativeClosePress(_ event: NSEvent) {
        guard !sessionSuspended, settings.enabled, let cg = event.cgEvent,
              let app = NSWorkspace.shared.frontmostApplication, WindowClosing.canQuit(app) else { return }
        let number = cg.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        guard let id = CGWindowID(exactly: number), id != kCGNullWindowID else { return }
        if let target, target.pid == app.processIdentifier {
            guard target.id == id, target.buttonFrame(for: 0)?.contains(cg.location) == true else { return }
        }
        recordNativeCloseWindow(of: app, click: (id, cg.location))
    }

    private func recordNativeCloseWindow(of app: NSRunningApplication, click: (id: CGWindowID, point: CGPoint)? = nil) {
        guard WindowClosing.canQuit(app), let bundleID = app.bundleIdentifier,
              !settings.quitExcludedBundleIDs.contains(bundleID),
              click != nil || WindowClosing.observesNativeClosure(of: app) else { return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.12)
        guard let window = AX.element(ax, kAXFocusedWindowAttribute),
              let close = AX.element(window, kAXCloseButtonAttribute), AX.flag(close, kAXEnabledAttribute),
              let button = AX.rect(close) else { return }
        if let click {
            guard button.contains(click.point),
                  AX.at(click.point, in: ax).map({ AX.same($0, close) }) == true else { return }
        }
        guard let frame = AX.rect(window), frame.contains(button) else { return }
        let matches = SystemWindow.visible().filter {
            $0.layer == 0 && $0.pid == app.processIdentifier && SystemWindow.close($0.bounds, frame)
        }
        guard matches.count == 1, let id = matches.first?.id, click == nil || click?.id == id else { return }
        closing.observeNativeWindow(app: app, window: window, id: id)
        if click != nil { closing.browserWindowMayHaveClosed(in: app.processIdentifier) }
    }

    private func armNativeGeometryDrag(_ event: NSEvent) {
        guard settings.enabled, let current = target, panel.isVisible,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid,
              let cgEvent = event.cgEvent,
              cgEvent.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == Int64(current.id) else { return }
        let point = cgEvent.location
        guard !WindowTarget.toAX(panel.frame).contains(point),
              let reserved = TrioLayout.availableRegion(window: current.frame, controls: current.buttonFrames, controlIndices: current.controlIndices),
              !reserved.contains(point) else { return }
        let nativeRow = current.buttonFrames.dropFirst().reduce(current.buttonFrames[0]) { $0.union($1) }
        let titleHeight = min(current.frame.height, max(0, 2*(nativeRow.midY-current.frame.minY)))
        let onTitle = point.x > nativeRow.maxX+5 &&
            point.x < current.frame.maxX && point.y >= current.frame.minY &&
            point.y <= current.frame.minY+titleHeight
        let onEdge = current.frame.insetBy(dx: -3, dy: -3).contains(point) &&
            !current.frame.insetBy(dx: 3, dy: 3).contains(point)
        guard onTitle || onEdge, let hit = AX.at(point), AX.pid(hit) == current.pid,
              let role = AX.string(hit, kAXRoleAttribute) else { return }
        let interactive: Set<String> = [kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole,
            kAXSliderRole, kAXMenuButtonRole, kAXPopUpButtonRole, NSAccessibility.Role.link.rawValue,
            kAXCheckBoxRole, kAXRadioButtonRole, kAXComboBoxRole]
        guard !interactive.contains(role) else { return }
        let windowBackground = role == kAXWindowRole && AX.same(hit, current.window)
        let staticTitle = role == kAXStaticTextRole &&
            (AX.element(current.window, kAXTitleUIElementAttribute).map { AX.same($0, hit) } ?? false)
        let titleBackground = onTitle && (windowBackground || role == kAXGroupRole || role == kAXToolbarRole || staticTitle)
        guard titleBackground || (onEdge && windowBackground) else { return }
        // Some custom toolbar elements expose a generic Group role but still
        // have a click action. They must retain their ordinary behavior.
        var actions: CFArray?
        if AXUIElementCopyActionNames(hit, &actions) == .success,
           let names = actions as? [String], names.contains(kAXPressAction) || names.contains(kAXShowMenuAction) { return }
        guard let focused = AX.element(AXUIElementCreateApplication(current.pid), kAXFocusedWindowAttribute),
              AX.same(focused, current.window),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid else { return }
        pendingNativeDrag = (current.pid, current.id, point)
    }

    private func beginArmedNativeDrag(_ event: NSEvent) {
        guard let armed = pendingNativeDrag, let current = target,
              current.pid == armed.pid, current.id == armed.id, panel.isVisible,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid,
              let point = event.cgEvent?.location,
              hypot(point.x-armed.point.x, point.y-armed.point.y) >= 2 else { return }
        pendingNativeDrag = nil
        guard let focused = AX.element(AXUIElementCreateApplication(current.pid), kAXFocusedWindowAttribute),
              AX.same(focused, current.window) else { return }
        diagnostic("tracking native-drag-start id=\(current.id)")
        beginManualGeometry(current)
        settleGeometry(after: 0.07)
    }

    @discardableResult
    private func checkDraggedGeometry() -> Bool {
        guard running, settings.enabled, !forwarding, animatingWindow == nil,
              let current = target, panel.isVisible else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid else { hide(); return false }
        let windows = SystemWindow.visible()
        guard let visible = windows.first(where: { $0.id == current.id && $0.pid == current.pid && $0.layer == 0 }) else {
            hide(); scheduleRefresh(after: 0.07); return false
        }
        // Selecting or dragging content does not change the visible window.
        guard !SystemWindow.close(visible.bounds, current.frame, tolerance: 0.1) else { return false }
        beginManualGeometry(current)
        settleGeometry(after: 0.07)
        return true
    }

    private func beginManualGeometry(_ current: WindowTarget) {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            manualGeometryInteraction = (current.pid, current.id, current.window)
        }
        diagnostic("tracking geometry-hide id=\(current.id) held=\(NSEvent.pressedMouseButtons & 1 != 0)")
        hide()
    }

    private func holdingManualGeometry() -> Bool {
        guard let interaction = manualGeometryInteraction else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == interaction.pid else {
            manualGeometryInteraction = nil; return false
        }
        if let focused = AX.element(AXUIElementCreateApplication(interaction.pid), kAXFocusedWindowAttribute),
           !AX.same(focused, interaction.window) {
            manualGeometryInteraction = nil; return false
        }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            manualGeometryInteraction = nil; return false
        }
        return true
    }

    private func settleGeometry(after delay: Double) {
        geometrySettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.geometrySettleWork = nil
            // A paused drag is still an interaction. The mouse-up event will
            // schedule the final survey; no polling timer is kept alive.
            guard !self.holdingManualGeometry() else { return }
            self.drawingNeedsControlGeometry = true
            self.needsFullLayoutRefresh = true
            self.scheduleRefresh(after: 0.01)
        }
        geometrySettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
    }

    private enum DrawingStability {
        case stable
        case transient(String)
        case changed(String)
    }

    /// Visual tracking intentionally does not read enabled states, descendants
    /// or rebuild button objects. Content-focus changes may transiently alter
    /// those AX values without changing the window supporting this drawing.
    private func drawingStability(of target: WindowTarget) -> DrawingStability {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return .changed("front-pid") }
        let windows = SystemWindow.visible()
        let ownID = panel.windowNumber
        guard ownID > 0, windows.contains(where: { $0.pid == getpid() && $0.id == CGWindowID(ownID) }) else {
            return .changed("panel-not-onscreen")
        }
        guard let index = windows.firstIndex(where: { $0.id == target.id && $0.pid == target.pid && $0.layer == 0 }) else {
            return .changed("cg-target-not-onscreen")
        }
        guard SystemWindow.close(windows[index].bounds, target.frame, tolerance: 1) else { return .changed("cg-frame") }
        let mask = WindowTarget.toAX(panel.frame)
        guard target.frame.contains(mask), !windows[..<index].contains(where: {
            $0.pid != getpid() && $0.layer == 0 && $0.bounds.intersects(mask)
        }) else { return .changed("cg-mask-obscured") }

        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        guard let focused = AX.element(app, kAXFocusedWindowAttribute) else { return .transient("ax-focused-unavailable") }
        guard AX.same(focused, target.window) else { return .changed("ax-focused-window") }
        if AX.flag(focused, kAXMinimizedAttribute) { return .changed("ax-minimized") }
        guard let frame = AX.rect(focused) else { return .transient("ax-frame-unavailable") }
        guard SystemWindow.close(frame, target.frame, tolerance: 1) else { return .changed("ax-frame") }
        if drawingNeedsControlGeometry {
            for (button, cached) in zip(target.buttons, target.buttonFrames) {
                guard let frame = AX.rect(button) else { return .transient("ax-control-geometry-unavailable") }
                guard SystemWindow.close(frame, cached, tolerance: 1) else { return .changed("ax-control-geometry") }
            }
            drawingNeedsControlGeometry = false
        }
        return .stable
    }

    private func retryDrawing(_ reason: String, attempt: Int) {
        guard running, settings.enabled, attempt < 3 else {
            diagnostic("tracking retry-exhausted reason=\(reason) attempt=\(attempt)")
            return
        }
        diagnostic("tracking retry reason=\(reason) attempt=\(attempt+1)")
        scheduleRefresh(after: 0.04 * Double(attempt+1), attempt: attempt+1)
    }

    func refresh() { refresh(attempt: 0) }

    private func refresh(attempt: Int) {
        if !settings.enabled || !settings.autoMaximizeNewWindows { cancelAutoMaximize(clearHistory: false) }
        guard running, !sessionSuspended, !forwarding else { return }
        if animatingWindow != nil { return }
        guard settings.enabled else { closing.reset(); hide(); onStatus("Trio pausado. Os controles originais estão disponíveis."); return }
        guard AXIsProcessTrusted() else { hide(); onStatus("Permita Acessibilidade para ativar os controles. Nenhuma permissão de gravação de tela é necessária."); return }
        guard !holdingManualGeometry() else { return }
        if let current = target, panel.isVisible,
           let visible = SystemWindow.visible().first(where: { $0.id == current.id && $0.pid == current.pid && $0.layer == 0 }),
           !SystemWindow.close(visible.bounds, current.frame, tolerance: 0.1) {
            beginManualGeometry(current)
            settleGeometry(after: 0.07)
            return
        }
        if let target, panel.isVisible {
            switch drawingStability(of: target) {
            case .stable:
                if appliedScale == settings.scale && !needsFullLayoutRefresh { return }
                // Keep the last safe drawing while a new scale is surveyed.
            case .transient(let reason):
                diagnostic("tracking refresh-keep-transient=\(reason)")
                retryDrawing(reason, attempt: attempt)
                return
            case .changed(let reason):
                diagnostic("tracking refresh-hide=\(reason)")
                hide()
            }
        }
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        guard let candidate = WindowTarget.focused() else {
            if let app = NSWorkspace.shared.frontmostApplication {
                closing.browserWindowMayHaveClosed(in: app.processIdentifier)
                recordNativeCloseWindow(of: app)
            }
            diagnostic("tracking candidate-unavailable attempt=\(attempt) kept=\(panel.isVisible)")
            retryDrawing("candidate-unavailable", attempt: attempt)
            if panel.isVisible {
                if needsFullLayoutRefresh && attempt >= 3 { hide() }
                else { return }
            }
            onStatus("Aguardando uma janela compatível. O Trio precisa identificar o botão de fechar da janela ativa."); return
        }
        if let previous = target,
           previous.pid != candidate.pid || previous.id != candidate.id || !AX.same(previous.window, candidate.window) {
            hide()
        }
        watch(candidate.window, pid: candidate.pid)
        watchControls(of: candidate)
        closing.observeBrowserWindow(candidate)
        func fit(_ indices: [Int]) -> (ControlLayout, CGRect, [CGRect])? {
            let frames = indices.compactMap { candidate.buttonFrame(for: $0) }
            guard frames.count == indices.count,
                  let region = TrioLayout.availableRegion(window: candidate.frame, controls: frames, controlIndices: indices),
                  var obstacles = candidate.obstacles(for: region) else { return nil }
            for slot in candidate.controlIndices where !indices.contains(slot) {
                if let rect = candidate.buttonFrame(for: slot) { obstacles.append(rect.insetBy(dx: -2, dy: -2)) }
            }
            guard case let .success(layout) = TrioLayout.calculate(window: candidate.frame, controls: frames,
                requestedScale: settings.scale, obstacles: obstacles, controlIndices: indices) else { return nil }
            return (layout, region, obstacles)
        }
        guard let (layout, reserve, obstacles) = fit(candidate.controlIndices) ??
            (candidate.controlIndices.count > 1 ? fit([0]) : nil) else {
            hide()
            retryDrawing("candidate-survey", attempt: attempt)
            onStatus("\(candidate.name): espaço insuficiente para os controles do Trio.")
            return
        }
        // Reserve the largest safe hover area within the same strict region.
        let expanded = CGRect(x: reserve.minX, y: reserve.minY, width: reserve.width, height: reserve.height)
        var mask = layout.frame
        for step in (0...20).reversed() {
            let t = CGFloat(step)/20
            let test = CGRect(x: layout.frame.minX+(expanded.minX-layout.frame.minX)*t,
                              y: layout.frame.minY+(expanded.minY-layout.frame.minY)*t,
                              width: layout.frame.width+(expanded.width-layout.frame.width)*t,
                              height: layout.frame.height+(expanded.height-layout.frame.height)*t)
            if !obstacles.contains(where: { $0.intersects(test) }) { mask = test; break }
        }
        guard candidate.isCurrent(), candidate.ownsTopmostFrame(mask) else {
            retryDrawing("candidate-final-validation", attempt: attempt)
            return
        }
        target = candidate
        needsFullLayoutRefresh = false
        appliedScale = settings.scale
        panel.setFrame(WindowTarget.toCocoa(mask), display: false)
        if !layout.controlIndices.contains(2) {
            greenMenu?.cancel()
            arrangementPanel.hide()
        }
        controls.configure(layout: layout, mask: mask)
        panel.ignoresMouseEvents = false
        panel.setAccessibilityHidden(false)
        controls.setAccessibilityHidden(false)
        panel.orderFrontRegardless()
        cancelResumeWork()
        onStatus(String(format: "%@: %.2f× nesta janela. Preferência %.1f×; onda limitada à área segura.", candidate.name, layout.effectiveScale, settings.scale))
    }
    private func perform(_ index: Int) {
        diagnostic("action \(index), front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0), target=\(target?.pid ?? 0)")
        guard running, !sessionSuspended, !forwarding, panel.isVisible, let target, settings.enabled, target.controlIndices.contains(index), target.isCurrent() else { diagnostic("rejected: no current target"); hide(); scheduleRefresh(); return }
        if index == 2 { greenMenu?.cancel(); toggleMaximize(target); return }
        if index == 0 {
            if closing.shouldForwardLastClose(target) && CGPreflightPostEventAccess() {
                forwardOriginalClick(index, target: target)
            } else {
                if !closing.close(target) { onStatus("O aplicativo não permitiu fechar esta janela.") }
                scheduleRefresh(after: 0.06)
            }
        } else if index == 1 { forwardOriginalClick(index, target: target) }
    }
    private final class ForwardClickState {
        let index: Int
        let button: AXUIElement
        let rect: CGRect
        let target: WindowTarget
        let point: CGPoint
        let originalPointer: CGPoint?
        let deadline: TimeInterval
        var attempts = 0
        var nudged = false
        var posted = false
        var pointerMovedByUser = false
        var localMonitor: Any?
        var globalMonitor: Any?

        init(index: Int, button: AXUIElement, rect: CGRect, target: WindowTarget) {
            self.index = index
            self.button = button
            self.rect = rect
            self.target = target
            point = CGPoint(x: rect.midX, y: rect.midY)
            originalPointer = CGEvent(source: nil)?.location
            deadline = ProcessInfo.processInfo.systemUptime + 0.3
        }
    }

    private func forwardOriginalClick(_ index: Int, target: WindowTarget) {
        guard !forwarding, running, settings.enabled, (index == 0 || index == 1), let button = target.button(for: index),
              let rect = target.buttonFrame(for: index),
              CGPreflightPostEventAccess() else {
            if index == 0, !forwarding, running, !sessionSuspended, settings.enabled,
               let button = target.button(for: 0), let rect = target.buttonFrame(for: 0) {
                let state = ForwardClickState(index: 0, button: button, rect: rect, target: target)
                fallbackForwardedRedToAX(state, failure: "O envio do clique original não está disponível.")
                return
            }
            diagnostic("rejected: event posting not authorized or forwarding unavailable")
            onStatus("O macOS não autorizou o envio do clique. O botão original foi preservado.")
            hide()
            return
        }
        let state = ForwardClickState(index: index, button: button, rect: rect, target: target)
        forwarding = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.015)
        hide()
        NSAccessibility.post(element: NSApplication.shared, notification: .layoutChanged)

        let movement: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        state.localMonitor = NSEvent.addLocalMonitorForEvents(matching: movement) { [weak state] event in
            MainActor.assumeIsolated {
                if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
                    state?.pointerMovedByUser = true
                }
            }
            return event
        }
        state.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: movement) { [weak state] event in
            MainActor.assumeIsolated {
                if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) {
                    state?.pointerMovedByUser = true
                }
            }
        }
        retryOriginalClick(state)
    }

    private func retryOriginalClick(_ state: ForwardClickState) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.attemptOriginalClick(state)
        }
    }

    private func attemptOriginalClick(_ state: ForwardClickState) {
        guard !state.posted else { return }
        guard forwarding, running, !sessionSuspended, settings.enabled,
              ProcessInfo.processInfo.systemUptime < state.deadline else {
            failOriginalClick(state, failure: "Não foi possível confirmar o controle original. Nenhuma ação foi enviada.")
            return
        }
        state.attempts += 1
        let windows = SystemWindow.visible()
        let ownCG = windows.filter { $0.pid == getpid() && $0.layer >= 0 && $0.bounds.contains(state.point) }
        let top = windows.first { $0.pid != getpid() && $0.layer == 0 && $0.bounds.contains(state.point) }
        guard !windows.isEmpty, top?.pid == state.target.pid, top?.id == state.target.id,
              originalClickTargetIsCurrent(state, windows: windows),
              ProcessInfo.processInfo.systemUptime < state.deadline else {
            diagnostic("forward attempt=\(state.attempts) rejected current/top/deadline ownCG=\(ownCG.map { $0.id })")
            failOriginalClick(state, failure: "A janela mudou antes do clique. Nenhuma ação foi enviada.")
            return
        }
        guard ownCG.isEmpty else {
            diagnostic("forward attempt=\(state.attempts) current=true top=true ownCG=\(ownCG.map { $0.id }) waiting-panel-removal")
            retryOriginalClick(state)
            return
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.015)
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(system, Float(state.point.x), Float(state.point.y), &hit)
        let hitPID = hit.map { AX.pid($0) } ?? 0
        let same = hit.map { AX.same($0, state.button) } ?? false
        diagnostic("forward attempt=\(state.attempts) current=true top=true ownCG=[] hitError=\(hitError.rawValue) hitPID=\(hitPID) same=\(same) nudged=\(state.nudged)")
        guard ProcessInfo.processInfo.systemUptime < state.deadline else {
            failOriginalClick(state, failure: "Não foi possível confirmar o controle original. Nenhuma ação foi enviada.")
            return
        }
        if hitPID == getpid() {
            if !state.nudged {
                guard let source = CGEventSource(stateID: .hidSystemState),
                      let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                         mouseCursorPosition: state.point, mouseButton: .left) else {
                    failOriginalClick(state, failure: "Não foi possível atualizar a posição do controle original.")
                    return
                }
                state.nudged = true
                move.flags = []
                move.post(tap: .cghidEventTap)
                diagnostic("forward attempt=\(state.attempts) posted-one-mouseMoved-cache-refresh")
            }
            retryOriginalClick(state)
            return
        }
        guard let hit else { retryOriginalClick(state); return }
        guard hitError == .success, hitPID == state.target.pid, same,
              AX.flag(hit, kAXEnabledAttribute),
              ProcessInfo.processInfo.systemUptime < state.deadline,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == state.target.pid,
              CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: state.point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: state.point, mouseButton: .left) else {
            failOriginalClick(state, failure: "O controle sob o ponteiro mudou. Nenhuma ação foi enviada.")
            return
        }
        down.flags = []
        up.flags = []
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        var afterForwardedClose: (() -> Void)?
        if state.index == 0 {
            // A real red click can also be intercepted by Smart Close. Permit
            // it only while this is still the proven last eligible window;
            // siblings, minimized windows and exceptions use native AX close.
            let refreshedWindows = SystemWindow.visible()
            guard originalClickTargetIsCurrent(state, windows: refreshedWindows),
                  ProcessInfo.processInfo.systemUptime < state.deadline else {
                failOriginalClick(state, failure: "A janela mudou antes do clique. Nenhuma ação foi enviada.")
                return
            }
            // Authorization itself checks the current window inventory and
            // exceptions. Keep it after the longer AX geometry validation,
            // without repeating the same inventory query via shouldForward.
            guard let authorized = closing.authorizeForwardedLastClose(state.target) else {
                fallbackForwardedRedToAX(state, failure: "A regra de fechamento mudou antes do clique.")
                return
            }
            afterForwardedClose = authorized
            // Refresh hit/top ownership and deadline after authorization's
            // potentially slow AX queries; no request is armed until the up.
            var finalHit: AXUIElement?
            let finalHitError = AXUIElementCopyElementAtPosition(system, Float(state.point.x), Float(state.point.y), &finalHit)
            guard finalHitError == .success, let finalHit, AX.pid(finalHit) == state.target.pid,
                  AX.same(finalHit, state.button), AX.flag(finalHit, kAXEnabledAttribute) else {
                failOriginalClick(state, failure: "O controle sob o ponteiro mudou. Nenhuma ação foi enviada.")
                return
            }
            let finalWindows = SystemWindow.visible()
            let finalTop = finalWindows.first { $0.pid != getpid() && $0.layer == 0 && $0.bounds.contains(state.point) }
            guard forwarding, running, !sessionSuspended, settings.enabled,
                  ProcessInfo.processInfo.systemUptime < state.deadline,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == state.target.pid,
                  finalTop?.pid == state.target.pid, finalTop?.id == state.target.id,
                  finalTop.map({ SystemWindow.close($0.bounds, state.target.frame, tolerance: 1) }) == true,
                  !finalWindows.contains(where: { $0.pid == getpid() && $0.layer >= 0 && $0.bounds.contains(state.point) }),
                  CGPreflightPostEventAccess() else {
                failOriginalClick(state, failure: "Não foi possível confirmar o controle original. Nenhuma ação foi enviada.")
                return
            }
        }
        let didPostForwardedClose = afterForwardedClose
        state.posted = true
        diagnostic("forward attempt=\(state.attempts) posting HID down/up to original button")
        down.post(tap: .cghidEventTap)
        // Always release the synthetic down, even if close/minimize changes
        // focus. Arm close observation only after both events were posted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            up.post(tap: .cghidEventTap)
            didPostForwardedClose?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            self?.finishOriginalClick(state, failure: nil)
        }
    }

    private func originalClickTargetIsCurrent(_ state: ForwardClickState, windows: [SystemWindow]) -> Bool {
        let target = state.target
        func withinBudget() -> Bool { ProcessInfo.processInfo.systemUptime < state.deadline }
        guard withinBudget(), NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              windows.filter({ $0.id == target.id && $0.pid == target.pid && $0.layer == 0 &&
                  SystemWindow.close($0.bounds, target.frame, tolerance: 1) }).count == 1 else { return false }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.015)
        guard let focused = AX.element(app, kAXFocusedWindowAttribute), AX.same(focused, target.window),
              withinBudget(), WindowTarget.isSupportedWindow(focused, hasCloseButton: target.controlIndices.contains(0)),
              !AX.flag(focused, kAXMinimizedAttribute), withinBudget(),
              let frame = AX.rect(focused), SystemWindow.close(frame, target.frame, tolerance: 1),
              withinBudget() else { return false }
        let attribute = state.index == 0 ? kAXCloseButtonAttribute : kAXMinimizeButtonAttribute
        guard let button = AX.element(focused, attribute),
              AX.same(button, state.button), withinBudget(),
              let rect = AX.rect(button), SystemWindow.close(rect, state.rect, tolerance: 1),
              AX.flag(button, kAXEnabledAttribute), withinBudget(),
              let children = AX.value(focused, kAXChildrenAttribute) as? [AXUIElement],
              withinBudget() else { return false }
        if state.index == 0 {
            guard AX.pid(button) == target.pid, AX.string(button, kAXRoleAttribute) == kAXButtonRole,
                  AX.string(button, kAXSubroleAttribute) == kAXCloseButtonSubrole,
                  withinBudget() else { return false }
        }
        for child in children {
            guard withinBudget(), let role = AX.string(child, kAXRoleAttribute), role != kAXSheetRole else { return false }
        }
        guard withinBudget() else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }

    private func failOriginalClick(_ state: ForwardClickState, failure: String) {
        if state.index == 0 && !state.posted {
            fallbackForwardedRedToAX(state, failure: failure)
        } else {
            finishOriginalClick(state, failure: failure)
        }
    }

    private func fallbackForwardedRedToAX(_ state: ForwardClickState, failure: String) {
        guard state.index == 0, !state.posted else { return }
        // No down/up was posted, so this is the single close action, not a
        // second click. Restore forwarding state before revalidating its target.
        diagnostic("red forward fallback before mouseDown: \(failure)")
        finishOriginalClick(state, failure: nil)
        guard running, !sessionSuspended, settings.enabled, state.target.isCurrent(),
              state.target.ownsTopmostFrame(state.rect) else {
            onStatus(failure)
            return
        }
        if !closing.close(state.target) { onStatus("O aplicativo não permitiu fechar esta janela.") }
        scheduleRefresh(after: 0.06)
    }

    private func finishOriginalClick(_ state: ForwardClickState, failure: String?) {
        if let monitor = state.localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = state.globalMonitor { NSEvent.removeMonitor(monitor) }
        state.localMonitor = nil
        state.globalMonitor = nil
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.12)
        if state.nudged || state.posted, !state.pointerMovedByUser,
           let original = state.originalPointer, let now = CGEvent(source: nil)?.location,
           hypot(now.x-state.point.x, now.y-state.point.y) < 2 {
            CGWarpMouseCursorPosition(original)
        }
        diagnostic("forward finished attempts=\(state.attempts) posted=\(state.posted) nudged=\(state.nudged) userMoved=\(state.pointerMovedByUser) failure=\(failure ?? "none")")
        forwarding = false
        if let failure { onStatus(failure) }
        if running { scheduleRefresh(after: 0.08) }
    }
    private func canResize(_ window: AXUIElement) -> Bool {
        AX.string(window, kAXRoleAttribute) == kAXWindowRole &&
        !AX.flag(window, kAXMinimizedAttribute) && AX.isSettable(window, kAXPositionAttribute) && AX.isSettable(window, kAXSizeAttribute) &&
        (AX.element(window, kAXZoomButtonAttribute).map { AX.flag($0, kAXEnabledAttribute) } ?? false)
    }
    private func maximizeNew(_ window: AXUIElement, pid: pid_t) {
        guard running, !sessionSuspended, settings.enabled, settings.autoMaximizeNewWindows,
              pid != getpid(), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular, AX.pid(window) == pid,
              !autoMaximizeRequests.contains(where: { $0.application.processIdentifier == pid && AX.same($0.window, window) }) else { return }
        autoMaximizeRequests.append(AutoMaximizeRequest(window: window, application: app, now: ProcessInfo.processInfo.systemUptime))
        scheduleAutoMaximize()
    }
    private func suppressAutoMaximize(_ window: AXUIElement, pid: pid_t) {
        if let request = autoMaximizeRequests.first(where: { $0.application.processIdentifier == pid && AX.same($0.window, window) }) {
            request.nextCheck = nil
        } else if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            let request = AutoMaximizeRequest(window: window, application: app, now: ProcessInfo.processInfo.systemUptime)
            request.nextCheck = nil; autoMaximizeRequests.append(request)
        }
        scheduleAutoMaximize()
    }
    private func cancelAutoMaximize(clearHistory: Bool) {
        autoMaximizeGeneration = UUID()
        autoMaximizeWork?.cancel(); autoMaximizeWork = nil
        autoMaximizeScheduledToken = nil
        if clearHistory { autoMaximizeRequests.removeAll() }
        else { for request in autoMaximizeRequests { request.nextCheck = nil } }
    }
    private func scheduleAutoMaximize() {
        autoMaximizeWork?.cancel(); autoMaximizeWork = nil
        autoMaximizeScheduledToken = nil
        guard running, !sessionSuspended, settings.enabled, settings.autoMaximizeNewWindows,
              let next = autoMaximizeRequests.compactMap(\.nextCheck).min() else { return }
        let generation = autoMaximizeGeneration
        let scheduledToken = UUID()
        autoMaximizeScheduledToken = scheduledToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.autoMaximizeGeneration == generation,
                  self.autoMaximizeScheduledToken == scheduledToken else { return }
            self.autoMaximizeWork = nil
            self.autoMaximizeScheduledToken = nil
            self.processAutoMaximize()
        }
        autoMaximizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, next - ProcessInfo.processInfo.systemUptime), execute: work)
    }
    private func processAutoMaximize() {
        guard running, !sessionSuspended, settings.enabled, settings.autoMaximizeNewWindows else {
            cancelAutoMaximize(clearHistory: false); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let request = autoMaximizeRequests.filter({ ($0.nextCheck ?? .infinity) <= now + 0.002 })
            .min(by: { ($0.nextCheck ?? .infinity) < ($1.nextCheck ?? .infinity) }) else { scheduleAutoMaximize(); return }
        defer { scheduleAutoMaximize() }
        let window = request.window, app = request.application, pid = app.processIdentifier
        // Consume before doing work. Only a bounded transient result requeues.
        request.nextCheck = nil
        guard !app.isTerminated, let currentApp = NSRunningApplication(processIdentifier: pid),
              currentApp.launchDate == app.launchDate, currentApp.activationPolicy == .regular,
              AX.pid(window) == pid, let bundleID = currentApp.bundleIdentifier,
              !settings.autoMaximizeExcludedBundleIDs.contains(bundleID) else {
            diagnostic("autoMax skip=application-or-exception pid=\(pid)"); return
        }
        // An explicit user gesture wins. Never finish a queued automatic
        // resize after the user has started moving/resizing a new window.
        guard NSEvent.pressedMouseButtons == 0, manualGeometryInteraction == nil,
              !restore.contains(where: { $0.pid == pid && AX.same($0.window, window) }) else {
            diagnostic("autoMax skip=user-interaction-or-arranged pid=\(pid)"); return
        }
        let busy = forwarding || animatingWindow != nil
        let frame = busy ? nil : AX.rect(window)
        switch request.stability.observe(frame: frame, at: now, blocked: busy) {
        case .wait(let delay): request.nextCheck = now + delay; return
        case .expired: diagnostic("autoMax skip=stabilization-timeout pid=\(pid)"); return
        case .ready: break
        }
        guard let frame, let screen = WindowTarget.screen(for: frame),
              let windows = AX.value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement],
              windows.contains(where: { AX.same($0, window) }) else { diagnostic("autoMax skip=unavailable pid=\(pid)"); return }
        let children = AX.value(window, kAXChildrenAttribute) as? [AXUIElement]
        let hasSheet = children == nil || (children?.count ?? 0) > 32 ||
            children?.contains(where: {
                guard ProcessInfo.processInfo.systemUptime < request.expiresAt else { return true }
                guard let role = AX.string($0, kAXRoleAttribute) else { return true }
                return role == kAXSheetRole
            }) == true
        guard ProcessInfo.processInfo.systemUptime < request.expiresAt else { diagnostic("autoMax skip=metadata-timeout pid=\(pid)"); return }
        let modalInApplication = windows.contains {
            guard ProcessInfo.processInfo.systemUptime < request.expiresAt else { return true }
            return AX.flag($0, kAXModalAttribute)
        }
        guard ProcessInfo.processInfo.systemUptime < request.expiresAt else { diagnostic("autoMax skip=metadata-timeout pid=\(pid)"); return }
        let standard = AX.string(window, kAXRoleAttribute) == kAXWindowRole &&
            AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole
        let normalLayer = SystemWindow.visible().contains { $0.pid == pid && $0.layer == 0 && SystemWindow.close($0.bounds, frame) }
        // Automatic eligibility is intentionally stricter than the green
        // button. A missing/disabled standard action leaves the window alone.
        let resizable = AX.isSettable(window, kAXPositionAttribute) && AX.isSettable(window, kAXSizeAttribute) &&
            [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute].allSatisfy {
                guard ProcessInfo.processInfo.systemUptime < request.expiresAt,
                      let button = AX.element(window, $0),
                      ProcessInfo.processInfo.systemUptime < request.expiresAt else { return false }
                return AX.flag(button, kAXEnabledAttribute)
            }
        let workArea = WindowTarget.toAX(screen.visibleFrame)
        let decision = AutoMaximizePolicy.decision(frame: frame, workArea: workArea, isStandard: standard,
                                                  isResizable: resizable, isAuxiliary: !normalLayer || hasSheet,
                                                  isModal: modalInApplication, isMinimized: AX.flag(window, kAXMinimizedAttribute),
                                                  isFullscreen: SystemWindow.close(frame, WindowTarget.toAX(screen.frame), tolerance: 2))
        diagnostic("autoMax decision=\(decision.rawValue) pid=\(pid) width=\(Int(frame.width)) height=\(Int(frame.height))")
        guard decision == .maximize, ProcessInfo.processInfo.systemUptime < request.expiresAt,
              !app.isTerminated, running, !sessionSuspended, settings.enabled, settings.autoMaximizeNewWindows,
              NSEvent.pressedMouseButtons == 0, manualGeometryInteraction == nil,
              let confirmed = AX.rect(window), SystemWindow.close(confirmed, frame, tolerance: 2),
              ProcessInfo.processInfo.systemUptime < request.expiresAt else { return }
        apply(workArea, to: window, pid: pid, preserve: true)
    }
    private func toggleMaximize(_ target: WindowTarget) {
        diagnostic("maximize current=\(target.isCurrent()) resize=\(canResize(target.window))")
        guard target.isCurrent(), canResize(target.window), let screen = WindowTarget.screen(for: target.frame) else { return }
        suppressAutoMaximize(target.window, pid: target.pid)
        hide()
        if let i = restore.firstIndex(where: { $0.pid == target.pid && AX.same($0.window, target.window) }),
           SystemWindow.close(target.frame, restore[i].applied, tolerance: 3) {
            let prior = restore[i]
            apply(clamped(prior.original, to: WindowTarget.toAX(screen.visibleFrame)), to: target.window, pid: target.pid, preserve: false, restoring: true)
        } else {
            apply(WindowTarget.toAX(screen.visibleFrame), to: target.window, pid: target.pid, preserve: true)
        }
        scheduleRefresh(after: 0.13)
    }
    private func apply(_ rect: CGRect, to window: AXUIElement, pid: pid_t, preserve: Bool, restoring: Bool = false) {
        guard let before = AX.rect(window), canResize(window) else { return }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
            (AX.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute).map { AX.same($0, window) } ?? false)
        // Complete the previous operation's cancellation before establishing
        // this operation's recovery record or animation token.
        if foreground { windowAnimator.cancel(); hide() }
        let operationToken = UUID()
        if preserve {
            restore.removeAll { $0.pid == pid && AX.same($0.window, window) }
            restore.append((pid, window, before, before))
        }
        let finish: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            if self.animationToken == operationToken,
               let animated = self.animatingWindow, AX.same(animated, window) {
                self.animatingWindow = nil
                self.animationToken = nil
            }
            guard self.running else { return }
            let applied = AX.rect(window)
            let completed = success && applied != nil &&
                (!restoring || SystemWindow.close(applied!, rect, tolerance: 3))
            guard completed, let applied else {
                // A cancelled animation can leave an intermediate frame.
                // Keep its original size recoverable on the next green click.
                if let partial = applied,
                   let index = self.restore.firstIndex(where: { $0.pid == pid && AX.same($0.window, window) }) {
                    self.restore[index].applied = partial
                }
                self.onStatus("Este aplicativo não permitiu concluir a organização da janela."); self.scheduleRefresh(); return
            }
            if preserve,
               let index = self.restore.firstIndex(where: { $0.pid == pid && AX.same($0.window, window) }) {
                self.restore[index].applied = applied
            } else {
                self.restore.removeAll { $0.pid == pid && AX.same($0.window, window) }
            }
            self.scheduleRefresh(after: 0.035)
        }
        if foreground && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !SystemWindow.close(before, rect, tolerance: 1) {
            animatingWindow = window; animationToken = operationToken
            windowAnimator.animate(window: window, from: before, to: rect, canContinue: { [weak self] in
                guard let self else { return false }
                guard self.running, !self.sessionSuspended, self.settings.enabled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let focused = AX.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
                      AX.same(focused, window), !AX.flag(window, kAXMinimizedAttribute) else { return false }
                return true
            }, completion: finish)
        } else { finish(AX.setFrame(rect, on: window)) }
    }
    private func clamped(_ rect: CGRect, to work: CGRect) -> CGRect {
        let size = CGSize(width: min(rect.width, work.width), height: min(rect.height, work.height))
        return CGRect(x: max(work.minX, min(rect.minX, work.maxX-size.width)), y: max(work.minY, min(rect.minY, work.maxY-size.height)), width: size.width, height: size.height)
    }
    private func scheduleGreenMenu() {
        greenMenu?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.controls.hover == 2, self.target?.isCurrent() == true else { return }
            self.arrangementMenu()
        }
        greenMenu = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.26, execute: work)
    }
    private func contextMenu() {
        greenMenu?.cancel()
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Abrir Trio", action: #selector(openSettings), keyEquivalent: ""); open.target = self
        let pause = menu.addItem(withTitle: "Pausar Trio", action: #selector(pause), keyEquivalent: ""); pause.target = self
        populateQuitItems(in: menu)
        menu.popUp(positioning: nil, at: controls.convert(panel.mouseLocationOutsideOfEventStream, from: nil), in: controls)
    }
    func populateQuitItems(in menu: NSMenu) {
        guard running, settings.enabled, !sessionSuspended,
              let app = NSWorkspace.shared.frontmostApplication, WindowClosing.canQuit(app),
              let name = app.localizedName else { return }
        menu.addItem(.separator())
        for (title, action) in [("Encerrar " + name, #selector(quitSelectedApp(_:))),
                                ("Forçar encerramento de " + name + "…", #selector(forceQuitSelectedApp(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = app
        }
    }

    private func appForMenuItem(_ sender: NSMenuItem) -> NSRunningApplication? {
        guard let app = sender.representedObject as? NSRunningApplication, WindowClosing.canQuit(app),
              settings.enabled, running, !sessionSuspended,
              NSWorkspace.shared.frontmostApplication == app else { return nil }
        return app
    }

    @objc private func quitSelectedApp(_ sender: NSMenuItem) {
        guard let app = appForMenuItem(sender) else { return }
        if !app.terminate() { onStatus("O aplicativo recusou o pedido de encerramento.") }
    }

    @objc private func forceQuitSelectedApp(_ sender: NSMenuItem) {
        guard let app = appForMenuItem(sender), let name = app.localizedName else { return }
        let alert = NSAlert()
        alert.messageText = "Forçar encerramento de " + name + "?"
        alert.informativeText = "Todas as janelas deste aplicativo serão encerradas. Alterações não salvas podem ser perdidas."
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Forçar encerramento")
        alert.alertStyle = .warning
        alert.window.level = .modalPanel
        guard alert.runModal() == .alertSecondButtonReturn, WindowClosing.canQuit(app) else { return }
        if !app.forceTerminate() { onStatus("O macOS recusou o encerramento forçado de " + name + ".") }
    }

    private func arrangementMenu() {
        arrangementPanel.show(below: panel.frame, relativeTo: panel.windowNumber)
        controls.holdGreenHover = arrangementPanel.isVisible
    }
    private func diagnostic(_ message: String) {
        if CommandLine.arguments.contains("--diagnostics") { FileHandle.standardError.write(Data(("[Trio] " + message + "\n").utf8)) }
    }
    @objc private func openSettings() { onOpen() }
    @objc private func pause() { settings.enabled = false; refresh() }
    @objc private func arrange(_ sender: NSMenuItem) {
        guard let target, target.button(for: 2) != nil, target.isCurrent(), canResize(target.window), let screen = WindowTarget.screen(for: target.frame) else { hide(); return }
        suppressAutoMaximize(target.window, pid: target.pid)
        if sender.tag == 0 { toggleMaximize(target); return }
        let work = WindowTarget.toAX(screen.visibleFrame)
        var frame = target.frame
        if sender.tag == 1 || sender.tag == 2 { frame = CGRect(x: work.minX + (sender.tag == 2 ? work.width/2 : 0), y: work.minY, width: work.width/2, height: work.height) }
        else { frame.origin = CGPoint(x: work.midX-frame.width/2, y: work.midY-frame.height/2); frame = clamped(frame, to: work) }
        hide()
        apply(frame, to: target.window, pid: target.pid, preserve: false)
    }
}
