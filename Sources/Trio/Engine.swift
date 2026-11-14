import AppKit
import ApplicationServices
import TrioCore

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
    private var target: WindowTarget?
    private var observers: [pid_t: AXObserver] = [:]
    private var watchedWindows: [pid_t: [AXUIElement]] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var pending: DispatchWorkItem?
    private var greenMenu: DispatchWorkItem?
    private var forwarding = false
    private var running = false
    private var appliedScale: Double?
    private var drawingNeedsControlGeometry = false
    private var needsFullLayoutRefresh = false
    private var dragFollowWork: DispatchWorkItem?
    private var geometrySettleWork: DispatchWorkItem?
    private var lastGeometryFollow: TimeInterval = 0
    private var manualGeometryInteraction: (pid: pid_t, id: CGWindowID, window: AXUIElement)?
    private let windowAnimator = WindowAnimator()
    private var animatingWindow: AXUIElement?
    private var animationToken: UUID?
    private var restore: [(pid: pid_t, window: AXUIElement, original: CGRect, applied: CGRect)] = []

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
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let changedApp = self.target?.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier
                    self.diagnostic("tracking workspace=\(name.rawValue) changedPID=\(changedApp)")
                    // Spaces and wake invalidate the drawing even when the
                    // same app/window is reported during the transition.
                    if name != NSWorkspace.didActivateApplicationNotification || changedApp { self.hide() }
                    self.scheduleRefresh(after: 0.04)
                }
            })
        }
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                for delay in [0.4, 0.9] {
                    DispatchQueue.main.asyncAfter(deadline: .now()+delay) {
                        guard let self, self.running, !app.isTerminated else { return }
                        self.observe(app)
                        if self.settings.enabled && self.settings.autoMaximizeNewWindows,
                           let windows = AX.value(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] {
                            for window in windows { self.maximizeNew(window, pid: app.processIdentifier) }
                        }
                        self.scheduleRefresh()
                    }
                }
            }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
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
        // Mouse-down is predictive only on verified native title-bar background
        // or a resize edge. Content and toolbar controls remain untouched.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.forwarding, self.animatingWindow == nil else { return }
                if event.type == .leftMouseDown { self.anticipateNativeGeometryDrag(event) }
                else if event.type == .leftMouseDragged { self.scheduleDragFollow() }
                else {
                    self.dragFollowWork?.cancel(); self.dragFollowWork = nil
                    let wasManual = self.manualGeometryInteraction != nil
                    let changed = self.checkDraggedGeometry()
                    self.manualGeometryInteraction = nil
                    if wasManual || changed { self.settleGeometry(after: 0.07) }
                }
            }
        }
        refresh()
    }
    func stop() {
        running = false; pending?.cancel(); greenMenu?.cancel(); hide()
        windowAnimator.cancel(); animatingWindow = nil
        manualGeometryInteraction = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token); NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        for pid in Array(observers.keys) { removeObserver(pid) }
    }
    private func removeObserver(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        watchedWindows[pid] = nil
        restore.removeAll { $0.pid == pid }
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
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
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
                     kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification] {
            _ = AXObserverAddNotification(observer, window, name as CFString, context)
        }
        watchedWindows[pid, default: []].append(window)
    }
    fileprivate func handle(_ element: AXUIElement, notification: String) {
        guard running else { return }
        let eventPID = AX.pid(element)
        let affectsTarget = target.map { AX.same($0.window, element) } ?? false
        diagnostic("tracking AX=\(notification) eventPID=\(eventPID) targetPID=\(target?.pid ?? 0) targetID=\(target?.id ?? 0) targetElement=\(affectsTarget)")
        if notification == kAXWindowCreatedNotification {
            let pid = eventPID
            watch(element, pid: pid)
            if settings.enabled && settings.autoMaximizeNewWindows {
                DispatchQueue.main.asyncAfter(deadline: .now()+0.18) { [weak self] in self?.maximizeNew(element, pid: pid) }
            }
        }
        if notification == kAXUIElementDestroyedNotification {
            restore.removeAll { AX.same($0.window, element) }
            let pid = AX.pid(element)
            watchedWindows[pid]?.removeAll { AX.same($0, element) }
        }
        guard !forwarding else { return }
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

    private func anticipateNativeGeometryDrag(_ event: NSEvent) {
        guard settings.enabled, let current = target, panel.isVisible,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid,
              let cgEvent = event.cgEvent,
              cgEvent.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == Int64(current.id) else { return }
        let point = cgEvent.location
        guard !WindowTarget.toAX(panel.frame).contains(point),
              let reserved = TrioLayout.availableRegion(window: current.frame, controls: current.buttonFrames),
              !reserved.contains(point) else { return }
        let nativeRow = current.buttonFrames.dropFirst().reduce(current.buttonFrames[0]) { $0.union($1) }
        let titleHeight = min(current.frame.height, max(0, 2*(nativeRow.midY-current.frame.minY)))
        let onTitle = point.x > current.buttonFrames[2].maxX+5 &&
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
        diagnostic("tracking predictive-geometry-hide id=\(current.id) title=\(titleBackground) edge=\(onEdge && windowBackground) role=\(role)")
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
        guard running, !forwarding else { return }
        if animatingWindow != nil { return }
        guard settings.enabled else { hide(); onStatus("Trio pausado. Os controles originais estão disponíveis."); return }
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
            diagnostic("tracking candidate-unavailable attempt=\(attempt) kept=\(panel.isVisible)")
            retryDrawing("candidate-unavailable", attempt: attempt)
            if panel.isVisible { return }
            onStatus("Aguardando uma janela compatível. Janelas sem três controles acessíveis permanecem com os originais."); return
        }
        if let previous = target,
           previous.pid != candidate.pid || previous.id != candidate.id || !AX.same(previous.window, candidate.window) {
            hide()
        }
        watch(candidate.window, pid: candidate.pid)
        guard let reserve = TrioLayout.availableRegion(window: candidate.frame, controls: candidate.buttonFrames),
              let obstacles = candidate.obstacles(for: reserve) else {
            retryDrawing("candidate-survey", attempt: attempt)
            if panel.isVisible { return }
            onStatus("\(candidate.name): não foi possível confirmar o espaço livre. Os controles originais foram preservados."); return
        }
        guard case .success(let layout) = TrioLayout.calculate(window: candidate.frame, controls: candidate.buttonFrames, requestedScale: settings.scale, obstacles: obstacles),
              layout.effectiveScale >= 1.02 else {
            if panel.isVisible { return }
            onStatus("\(candidate.name): espaço insuficiente para ampliar sem cobrir ferramentas."); return
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
        controls.configure(layout: layout, mask: mask)
        panel.ignoresMouseEvents = false
        panel.setAccessibilityHidden(false)
        controls.setAccessibilityHidden(false)
        panel.orderFrontRegardless()
        onStatus(String(format: "%@: %.2f× nesta janela. Preferência %.1f×; onda limitada à área segura.", candidate.name, layout.effectiveScale, settings.scale))
    }
    private func perform(_ index: Int) {
        diagnostic("action \(index), front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0), target=\(target?.pid ?? 0)")
        guard let target, settings.enabled, target.isCurrent() else { diagnostic("rejected: no current target"); hide(); scheduleRefresh(); return }
        if index == 2 { greenMenu?.cancel(); toggleMaximize(target); return }
        forwardOriginalClick(index, target: target)
    }
    private final class ForwardClickState {
        let index: Int
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

        init(index: Int, target: WindowTarget) {
            self.index = index
            self.target = target
            let rect = target.buttonFrames[index]
            point = CGPoint(x: rect.midX, y: rect.midY)
            originalPointer = CGEvent(source: nil)?.location
            deadline = ProcessInfo.processInfo.systemUptime + 0.3
        }
    }

    private func forwardOriginalClick(_ index: Int, target: WindowTarget) {
        guard !forwarding, running, settings.enabled, index == 0 || index == 1,
              CGPreflightPostEventAccess() else {
            diagnostic("rejected: event posting not authorized or forwarding unavailable")
            onStatus("O macOS não autorizou o envio do clique. O botão original foi preservado.")
            hide()
            return
        }
        let state = ForwardClickState(index: index, target: target)
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
        guard forwarding, running, settings.enabled,
              ProcessInfo.processInfo.systemUptime < state.deadline else {
            finishOriginalClick(state, failure: "Não foi possível confirmar o controle original. Nenhuma ação foi enviada.")
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
            finishOriginalClick(state, failure: "A janela mudou antes do clique. Nenhuma ação foi enviada.")
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
        let same = hit.map { AX.same($0, state.target.buttons[state.index]) } ?? false
        diagnostic("forward attempt=\(state.attempts) current=true top=true ownCG=[] hitError=\(hitError.rawValue) hitPID=\(hitPID) same=\(same) nudged=\(state.nudged)")
        guard ProcessInfo.processInfo.systemUptime < state.deadline else {
            finishOriginalClick(state, failure: "Não foi possível confirmar o controle original. Nenhuma ação foi enviada.")
            return
        }
        if hitPID == getpid() {
            if !state.nudged {
                guard let source = CGEventSource(stateID: .hidSystemState),
                      let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                         mouseCursorPosition: state.point, mouseButton: .left) else {
                    finishOriginalClick(state, failure: "Não foi possível atualizar a posição do controle original.")
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
            finishOriginalClick(state, failure: "O controle sob o ponteiro mudou. Nenhuma ação foi enviada.")
            return
        }
        down.flags = []
        up.flags = []
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        state.posted = true
        diagnostic("forward attempt=\(state.attempts) posting HID down/up to original button")
        down.post(tap: .cghidEventTap)
        // Always release the synthetic down, including when Smart Close changes focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { up.post(tap: .cghidEventTap) }
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
              withinBudget(), AX.string(focused, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              !AX.flag(focused, kAXMinimizedAttribute), withinBudget(),
              let frame = AX.rect(focused), SystemWindow.close(frame, target.frame, tolerance: 1),
              withinBudget() else { return false }
        let attributes = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute]
        guard let button = AX.element(focused, attributes[state.index]),
              AX.same(button, target.buttons[state.index]), withinBudget(),
              let rect = AX.rect(button), SystemWindow.close(rect, target.buttonFrames[state.index], tolerance: 1),
              AX.flag(button, kAXEnabledAttribute), withinBudget(),
              let children = AX.value(focused, kAXChildrenAttribute) as? [AXUIElement],
              withinBudget() else { return false }
        for child in children {
            guard withinBudget(), let role = AX.string(child, kAXRoleAttribute), role != kAXSheetRole else { return false }
        }
        guard withinBudget() else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
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
        AX.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole &&
        !AX.flag(window, kAXMinimizedAttribute) && AX.isSettable(window, kAXPositionAttribute) && AX.isSettable(window, kAXSizeAttribute) &&
        [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute].allSatisfy { AX.element(window, $0).map { AX.flag($0, kAXEnabledAttribute) } ?? false }
    }
    private func maximizeNew(_ window: AXUIElement, pid: pid_t) {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              !settings.autoMaximizeExcludedBundleIDs.contains(bundleID) else { return }
        guard running, settings.enabled, settings.autoMaximizeNewWindows, pid != getpid(), canResize(window),
              !(animatingWindow.map { AX.same($0, window) } ?? false),
              let frame = AX.rect(window), let screen = WindowTarget.screen(for: frame),
              !SystemWindow.close(frame, WindowTarget.toAX(screen.frame), tolerance: 1),
              !restore.contains(where: { $0.pid == pid && AX.same($0.window, window) }) else { return }
        apply(WindowTarget.toAX(screen.visibleFrame), to: window, pid: pid, preserve: true)
    }
    private func toggleMaximize(_ target: WindowTarget) {
        diagnostic("maximize current=\(target.isCurrent()) resize=\(canResize(target.window))")
        guard target.isCurrent(), canResize(target.window), let screen = WindowTarget.screen(for: target.frame) else { return }
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
                guard self.running, self.settings.enabled,
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
        menu.popUp(positioning: nil, at: controls.convert(panel.mouseLocationOutsideOfEventStream, from: nil), in: controls)
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
        guard let target, target.isCurrent(), let screen = WindowTarget.screen(for: target.frame) else { hide(); return }
        if sender.tag == 0 { toggleMaximize(target); return }
        let work = WindowTarget.toAX(screen.visibleFrame)
        var frame = target.frame
        if sender.tag == 1 || sender.tag == 2 { frame = CGRect(x: work.minX + (sender.tag == 2 ? work.width/2 : 0), y: work.minY, width: work.width/2, height: work.height) }
        else { frame.origin = CGPoint(x: work.midX-frame.width/2, y: work.midY-frame.height/2); frame = clamped(frame, to: work) }
        hide()
        apply(frame, to: target.window, pid: target.pid, preserve: false)
    }
}
