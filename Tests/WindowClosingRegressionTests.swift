import AppKit
import ApplicationServices

// Run: swiftc -swift-version 5 Sources/Trio/WindowClosing.swift Tests/WindowClosingRegressionTests.swift -o /tmp/trio-closing-test && /tmp/trio-closing-test
// Platform shims keep the production coordinator unchanged and make time,
// AX inventory and process termination fully deterministic. No IPC is sent.
final class FakeElement {
    let id: Int
    var minimized = false
    var modal = false
    let role: String
    let subrole: String
    let hasWindowControls: Bool
    init(_ id: Int, role: String = kAXWindowRole, subrole: String = kAXStandardWindowSubrole,
         hasWindowControls: Bool = true) {
        self.id = id; self.role = role; self.subrole = subrole; self.hasWindowControls = hasWindowControls
    }
}
typealias AXUIElement = FakeElement
@MainActor private var inventories: [pid_t: [AXUIElement]] = [:]
@MainActor private var applicationElements: [pid_t: AXUIElement] = [:]
@MainActor private var performedAXActions = 0
func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ seconds: Float) -> AXError { .success }
@MainActor func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError {
    performedAXActions += 1
    return .success
}
@MainActor enum AX {
    static func value(_ element: ApplicationServices.AXUIElement, _ attribute: String) -> Any? {
        attribute == kAXWindowsAttribute ? inventories[NSWorkspace.shared.frontmostApplication!.processIdentifier] : nil
    }
    static func value(_ element: AXUIElement, _ attribute: String) -> Any? {
        if attribute == kAXWindowsAttribute, let pid = applicationElements.first(where: { $0.value === element })?.key { return inventories[pid] }
        if attribute == kAXChildrenAttribute { return [AXUIElement]() }
        if attribute == kAXRoleAttribute { return element.role }
        if attribute == kAXSubroleAttribute { return element.subrole }
        if attribute == kAXEnabledAttribute { return true }
        if attribute == kAXModalAttribute { return element.modal }
        if [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, kAXFullScreenButtonAttribute].contains(attribute),
           element.hasWindowControls {
            return AXUIElement(element.id + 10_000, role: kAXButtonRole, subrole: "AXUnknown", hasWindowControls: false)
        }
        return nil
    }
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? { value(element, attribute) as? AXUIElement }
    static func same(_ first: AXUIElement, _ second: AXUIElement) -> Bool { first === second }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        switch attribute {
        case kAXRoleAttribute: return element.role
        case kAXSubroleAttribute: return element.subrole
        default: return nil
        }
    }
    static func flag(_ element: AXUIElement, _ attribute: String) -> Bool {
        switch attribute {
        case kAXMinimizedAttribute: return element.minimized
        case kAXModalAttribute: return element.modal
        case kAXEnabledAttribute: return true
        default: return false
        }
    }
}

private final class FakeApplicationState {
    let pid: pid_t
    let bundleIdentifier: String
    let launchDate: Date?
    var kernelBirth: UInt64?
    var isTerminated = false, isHidden = false
    var terminateCalls = 0, forceTerminateCalls = 0
    var ignoresForceTerminate = false
    var forceTimes: [Double] = []
    init(pid: pid_t, bundleIdentifier: String, launchDate: Date?, kernelBirth: UInt64) {
        self.pid = pid; self.bundleIdentifier = bundleIdentifier; self.launchDate = launchDate
        self.kernelBirth = kernelBirth
    }
}
@MainActor struct NSRunningApplication {
    private static var registry: [pid_t: FakeApplicationState] = [:]
    private static var nextKernelBirth: UInt64 = 10_000
    private let state: FakeApplicationState
    var processIdentifier: pid_t { state.pid }
    var bundleIdentifier: String? { state.bundleIdentifier }
    var activationPolicy: NSApplication.ActivationPolicy { .regular }
    var isTerminated: Bool { state.isTerminated }
    var launchDate: Date? { state.launchDate }
    var kernelBirth: UInt64? {
        get { state.kernelBirth }
        nonmutating set { state.kernelBirth = newValue }
    }
    var ignoresForceTerminate: Bool {
        get { state.ignoresForceTerminate }
        nonmutating set { state.ignoresForceTerminate = newValue }
    }
    var firstForceAt: Double? { state.forceTimes.first }
    var isHidden: Bool {
        get { state.isHidden }
        nonmutating set { state.isHidden = newValue }
    }
    var terminateCalls: Int { state.terminateCalls }
    var forceTerminateCalls: Int { state.forceTerminateCalls }
    init(ownedPID: pid_t, bundleIdentifier: String = "com.allm4.Trio.OwnedRegression",
         launchDate: Date? = Date(timeIntervalSince1970: 1_000)) {
        Self.nextKernelBirth += 1
        state = FakeApplicationState(pid: ownedPID, bundleIdentifier: bundleIdentifier, launchDate: launchDate,
                                     kernelBirth: Self.nextKernelBirth)
        Self.registry[ownedPID] = state
    }
    init?(processIdentifier: pid_t) {
        guard let stored = Self.registry[processIdentifier] else { return nil }
        state = stored
    }
    func terminate() -> Bool { state.terminateCalls += 1; state.isTerminated = true; return true }
    func forceTerminate() -> Bool {
        state.forceTerminateCalls += 1; state.forceTimes.append(DispatchQueue.main.now)
        guard !state.ignoresForceTerminate else { return false }
        state.isTerminated = true; return true
    }
    func markTerminatedForTest() { state.isTerminated = true }
    static func == (first: NSRunningApplication, second: NSRunningApplication) -> Bool { first.state === second.state }
    static func == (first: NSRunningApplication?, second: NSRunningApplication) -> Bool { first.map { $0.state === second.state } ?? false }
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication: NSRunningApplication?
}
struct SystemWindow {
    struct FloatingEvidence {
        let owner: pid_t
        let layer: Int
        let size: CGSize
    }
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    @MainActor static var snapshot: [SystemWindow] = []
    @MainActor static var existingIDs: Set<CGWindowID> = []
    @MainActor static var floatingEvidence: [Int: FloatingEvidence] = [:]
    @MainActor static func visible() -> [SystemWindow] { snapshot }
    @MainActor static func noLongerExists(_ id: CGWindowID) -> Bool { !existingIDs.contains(id) }
    @MainActor static func hasNoVisibleWindow(ownedBy pid: pid_t) -> Bool {
        !snapshot.isEmpty && !snapshot.contains { $0.pid == pid && $0.layer == 0 }
    }
    @MainActor static func isFloatingSurface(_ window: AXUIElement, ownedBy pid: pid_t) -> Bool {
        guard let evidence = floatingEvidence[window.id] else { return false }
        return evidence.owner == pid && evidence.layer > 0 && evidence.size.width > 0 && evidence.size.height > 0
    }
}
struct WindowTarget {
    let id: CGWindowID
    let pid: pid_t
    let window: AXUIElement
    private let close = AXUIElement(2)
    func button(for index: Int) -> AXUIElement? { index == 0 ? close : nil }
    func buttonFrame(for index: Int) -> CGRect? { index == 0 ? CGRect(x: 10, y: 10, width: 12, height: 12) : nil }
    func ownsTopmostFrame(_ frame: CGRect) -> Bool { true }
    func isCurrent() -> Bool { true }
}

final class DispatchWorkItem {
    let body: () -> Void
    private(set) var cancelled = false
    init(block: @escaping () -> Void) { body = block }
    func cancel() { cancelled = true }
}
struct TestDeadline {
    let seconds: Double
    @MainActor static func now() -> Self { Self(seconds: DispatchQueue.main.now) }
    static func + (left: Self, right: Double) -> Self { Self(seconds: left.seconds + right) }
}
@MainActor final class DispatchQueue {
    static let main = DispatchQueue()
    var now: Double = 0
    private var tasks: [(deadline: Double, order: Int, work: () -> Void)] = []
    private var order = 0
    func reset() { now = 0; tasks.removeAll(); order = 0 }
    func asyncAfter(deadline: TestDeadline, execute: @escaping () -> Void) {
        order += 1; tasks.append((deadline.seconds, order, execute))
    }
    func asyncAfter(deadline: TestDeadline, execute: DispatchWorkItem) {
        asyncAfter(deadline: deadline) { if !execute.cancelled { execute.body() } }
    }
    func advance(to target: Double) {
        while let next = tasks.indices.filter({ tasks[$0].deadline <= target + 0.000_001 }).min(by: {
            tasks[$0].deadline == tasks[$1].deadline ? tasks[$0].order < tasks[$1].order : tasks[$0].deadline < tasks[$1].deadline
        }) {
            let task = tasks.remove(at: next); now = task.deadline; task.work()
        }
        now = target
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Regression assertion failed") {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@MainActor private func makeClosing(mayQuitOnLastWindow: @escaping (NSRunningApplication) -> Bool) -> WindowClosing {
    WindowClosing(processBirth: { NSRunningApplication(processIdentifier: $0)?.kernelBirth }, forceStalledProcess: { _ in
        expect(false, "A responsive fake process must never need escalation")
        return false
    }, mayQuitOnLastWindow: mayQuitOnLastWindow)
}

@main struct WindowClosingRegressionTests {
    @MainActor static func main() {
        earlyDestructionEventuallyForcesOnce()
        anotherMinimizedWindowCancelsPermanently()
        for (index, identifier) in ["com.microsoft.edgemac", "com.google.antigravity"].enumerated() {
            let pid = pid_t(97100 + index)
            singleEventEventuallyForces(identifier: identifier, pid: pid)
            minimizedBrowserSurvives(identifier: identifier, pid: pid)
            hiddenBrowserIsProtected(identifier: identifier, pid: pid)
            browserExceptionIsProtected(identifier: identifier, pid: pid)
            newBrowserWindowCancelsPendingClose(identifier: identifier, pid: pid)
        }
        unavailableRedInventoryNeedsProof()
        auxiliaryCreationOutsideInventoryDoesNotCancelRed()
        unknownControlLessSurfaceDelaysButDoesNotCancelRed()
        stalledForceNeedsFreshWindowAndInstanceProof()
        forwardedLastCloseAuthorizationPreservesWindowOwnership()
        floatingControlLessDialogsRequirePublicGeometryProof()
        kernelBirthValidatesIdentityWhenFoundationDateIsUnavailable()
        print("PASS: direct force; delayed inventory; auxiliary/floating dialog proof; Edge/Antigravity; multiple/minimized/modal/excluded windows protected; stalled-process escalation revalidates AX/CG and kernel identity; forwarding authorization never sends another close. No UI, real AX actions or signals.")
    }

    @MainActor private static func earlyDestructionEventuallyForcesOnce() {
        DispatchQueue.main.reset()
        let pid: pid_t = 97001
        let app = NSRunningApplication(ownedPID: pid)
        let window = AXUIElement(1)
        applicationElements[pid] = AXUIElement(3)
        inventories[pid] = [window]
        NSWorkspace.shared.frontmostApplication = app
        SystemWindow.snapshot = [SystemWindow(id: 101, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [101, 999]
        let closing = makeClosing(mayQuitOnLastWindow: { _ in true })
        expect(closing.close(WindowTarget(id: 101, pid: pid, window: window)))
        DispatchQueue.main.advance(to: 0.01)
        closing.windowDestroyed(window)
        // Destruction was announced, but AX and the compositor still retain it.
        DispatchQueue.main.advance(to: 0.46)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 0)
        DispatchQueue.main.advance(to: 0.70)
        inventories[pid] = []
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [999]
        DispatchQueue.main.advance(to: 4.0)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 1, "An early AX destruction must eventually force once, without a normal quit")
        DispatchQueue.main.advance(to: 5.5)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 1, "Stale surveys must not repeat forced termination")
    }

    @MainActor private static func anotherMinimizedWindowCancelsPermanently() {
        DispatchQueue.main.reset()
        let pid: pid_t = 97003
        let app = NSRunningApplication(ownedPID: pid)
        let original = AXUIElement(10), minimized = AXUIElement(11)
        minimized.minimized = true
        applicationElements[pid] = AXUIElement(12)
        inventories[pid] = [original]
        NSWorkspace.shared.frontmostApplication = app
        SystemWindow.snapshot = [SystemWindow(id: 201, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [201, 999]
        let closing = makeClosing(mayQuitOnLastWindow: { _ in true })
        expect(closing.close(WindowTarget(id: 201, pid: pid, window: original)))
        DispatchQueue.main.advance(to: 0.01)
        closing.windowDestroyed(original)
        inventories[pid] = [minimized]
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [202, 999]
        DispatchQueue.main.advance(to: 0.7)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 0, "Another minimized AX window must veto quitting even when CG has none visible")
        inventories[pid] = []
        SystemWindow.existingIDs = [999]
        closing.windowDestroyed(minimized)
        DispatchQueue.main.advance(to: 6)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 0,
               "Discovering another window must permanently cancel the earlier last-window authorization")
    }

    @MainActor private static func observedBrowser(identifier: String, pid: pid_t,
                                                  mayQuit: @escaping (NSRunningApplication) -> Bool = { _ in true })
        -> (app: NSRunningApplication, window: AXUIElement, closing: WindowClosing) {
        DispatchQueue.main.reset()
        let app = NSRunningApplication(ownedPID: pid, bundleIdentifier: identifier)
        let window = AXUIElement(20)
        applicationElements[pid] = AXUIElement(21)
        inventories[pid] = [window]
        NSWorkspace.shared.frontmostApplication = app
        SystemWindow.snapshot = [SystemWindow(id: 301, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [301, 999]
        let closing = makeClosing(mayQuitOnLastWindow: mayQuit)
        closing.observeBrowserWindow(WindowTarget(id: 301, pid: pid, window: window))
        return (app, window, closing)
    }

    @MainActor private static func singleEventEventuallyForces(identifier: String, pid: pid_t) {
        let scenario = observedBrowser(identifier: identifier, pid: pid)
        // Exactly one event arrives while both inventories still retain the
        // target. All subsequent transitions below have no event or callback.
        scenario.closing.browserWindowMayHaveClosed(in: pid)
        DispatchQueue.main.advance(to: 0.2)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 0, "\(identifier): initial event cannot close a surviving window")
        inventories[pid] = []
        DispatchQueue.main.advance(to: 0.6)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 0, "\(identifier): visible WindowServer window vetoes empty AX")
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        DispatchQueue.main.advance(to: 1.3)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 0, "\(identifier): retained CG ID still vetoes quitting")
        SystemWindow.existingIDs = [999]
        DispatchQueue.main.advance(to: 4.8)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 1,
               "\(identifier): first event must force once after delayed cleanup, without a second event or normal quit")
    }

    @MainActor private static func minimizedBrowserSurvives(identifier: String, pid: pid_t) {
        let scenario = observedBrowser(identifier: identifier, pid: pid)
        scenario.window.minimized = true
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        scenario.closing.browserWindowMayHaveClosed(in: pid)
        DispatchQueue.main.advance(to: 0.3)
        inventories[pid] = [] // A transient incomplete AX inventory is not closure.
        DispatchQueue.main.advance(to: 1.3)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 0, "\(identifier): minimized window with a retained ID must survive transient empty AX")
        inventories[pid] = [scenario.window]
        DispatchQueue.main.advance(to: 6)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 0,
               "\(identifier): minimizing is not a close")
    }

    @MainActor private static func hiddenBrowserIsProtected(identifier: String, pid: pid_t) {
        let scenario = observedBrowser(identifier: identifier, pid: pid)
        scenario.closing.browserWindowMayHaveClosed(in: pid)
        scenario.app.isHidden = true
        inventories[pid] = []
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [999]
        DispatchQueue.main.advance(to: 6)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 0,
               "\(identifier): hiding the app must protect it after the initial event")
    }

    @MainActor private static func browserExceptionIsProtected(identifier: String, pid: pid_t) {
        var allowed = true
        let scenario = observedBrowser(identifier: identifier, pid: pid, mayQuit: { _ in allowed })
        scenario.closing.browserWindowMayHaveClosed(in: pid)
        allowed = false
        inventories[pid] = []
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [999]
        DispatchQueue.main.advance(to: 6)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 0,
               "\(identifier): current app exceptions override an already queued close")
    }

    @MainActor private static func newBrowserWindowCancelsPendingClose(identifier: String, pid: pid_t) {
        let scenario = observedBrowser(identifier: identifier, pid: pid)
        scenario.closing.browserWindowMayHaveClosed(in: pid)
        let newWindow = AXUIElement(30)
        inventories[pid] = [newWindow]
        SystemWindow.snapshot = [SystemWindow(id: 302, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [302, 999]
        scenario.closing.windowOpened(newWindow, in: pid)
        DispatchQueue.main.advance(to: 0.5)
        inventories[pid] = []
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [999]
        DispatchQueue.main.advance(to: 6)
        expect(scenario.app.terminateCalls == 0 && scenario.app.forceTerminateCalls == 0,
               "\(identifier): opening a different window permanently cancels the earlier close")
    }

    @MainActor private static func unavailableRedInventoryNeedsProof() {
        DispatchQueue.main.reset()
        let pid: pid_t = 97200
        let app = NSRunningApplication(ownedPID: pid)
        let window = AXUIElement(40)
        NSWorkspace.shared.frontmostApplication = app
        inventories[pid] = nil
        SystemWindow.snapshot = [SystemWindow(id: 401, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [401, 999]
        let closing = makeClosing(mayQuitOnLastWindow: { _ in true })
        expect(closing.close(WindowTarget(id: 401, pid: pid, window: window)))
        DispatchQueue.main.advance(to: 0.3)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 0, "Unavailable AX cannot authorize quitting")
        inventories[pid] = []
        DispatchQueue.main.advance(to: 0.6)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 0, "A successful red action alone cannot replace CG disappearance proof")
        SystemWindow.existingIDs = [999]
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        DispatchQueue.main.advance(to: 4.8)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 1,
               "An initially unavailable red inventory can force once only after empty AX and a disappeared CG ID")
    }

    @MainActor private static func auxiliaryCreationOutsideInventoryDoesNotCancelRed() {
        DispatchQueue.main.reset()
        let pid: pid_t = 97300
        let app = NSRunningApplication(ownedPID: pid)
        let original = AXUIElement(50)
        let auxiliary = AXUIElement(51, subrole: "AXUnknown", hasWindowControls: false)
        NSWorkspace.shared.frontmostApplication = app
        inventories[pid] = [original]
        SystemWindow.snapshot = [SystemWindow(id: 501, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [501, 999]
        let closing = makeClosing(mayQuitOnLastWindow: { _ in true })
        expect(closing.close(WindowTarget(id: 501, pid: pid, window: original)))
        closing.windowOpened(auxiliary, in: pid) // Not an AXWindows member.
        DispatchQueue.main.advance(to: 0.3)
        expect(app.forceTerminateCalls == 0, "The original window still exists")
        inventories[pid] = []
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [999]
        DispatchQueue.main.advance(to: 4.8)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 1,
               "An auxiliary AXWindowCreated outside AXWindows must not cancel the verified red close")
    }

    @MainActor private static func unknownControlLessSurfaceDelaysButDoesNotCancelRed() {
        DispatchQueue.main.reset()
        let pid: pid_t = 97301
        let app = NSRunningApplication(ownedPID: pid)
        let original = AXUIElement(60)
        let auxiliary = AXUIElement(61, subrole: "AXUnknown", hasWindowControls: false)
        NSWorkspace.shared.frontmostApplication = app
        inventories[pid] = [original, auxiliary]
        SystemWindow.snapshot = [SystemWindow(id: 601, pid: pid, layer: 0), SystemWindow(id: 602, pid: pid, layer: 0),
                                 SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [601, 602, 999]
        let closing = makeClosing(mayQuitOnLastWindow: { _ in true })
        expect(closing.close(WindowTarget(id: 601, pid: pid, window: original)))
        DispatchQueue.main.advance(to: 0.2)
        inventories[pid] = [auxiliary]
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [602, 999]
        DispatchQueue.main.advance(to: 0.7)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 0,
               "An unknown surface still in AXWindows must delay all termination")
        inventories[pid] = []
        SystemWindow.existingIDs = [999]
        DispatchQueue.main.advance(to: 4.8)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 1,
               "Once the target ID and the unknown control-less surface disappear, the correlated close can finish")
    }

    @MainActor private static func stalledForceNeedsFreshWindowAndInstanceProof() {
        enum Change { case none, minimizedWindow, replacementInstance, visibleWindow }
        for (index, change) in [Change.none, .minimizedWindow, .replacementInstance, .visibleWindow].enumerated() {
            DispatchQueue.main.reset()
            let pid = pid_t(97400 + index)
            let app = NSRunningApplication(ownedPID: pid)
            app.ignoresForceTerminate = true
            let original = AXUIElement(70)
            NSWorkspace.shared.frontmostApplication = app
            inventories[pid] = [original]
            SystemWindow.snapshot = [SystemWindow(id: 701, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
            SystemWindow.existingIDs = [701, 999]
            var signals: [pid_t] = []
            let closing = WindowClosing(processBirth: { NSRunningApplication(processIdentifier: $0)?.kernelBirth }, forceStalledProcess: { signaledPID in
                signals.append(signaledPID)
                app.markTerminatedForTest()
                return true
            }, mayQuitOnLastWindow: { _ in true })
            expect(closing.close(WindowTarget(id: 701, pid: pid, window: original)))
            inventories[pid] = []
            SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
            SystemWindow.existingIDs = [999]
            DispatchQueue.main.advance(to: 0.2)
            expect(app.terminateCalls == 0 && app.forceTerminateCalls >= 1,
                   "The test process deliberately ignores the public forceTerminate request")
            guard let forceAt = app.firstForceAt else { expect(false, "Missing first force timestamp"); return }
            switch change {
            case .none: break
            case .minimizedWindow:
                let window = AXUIElement(71); window.minimized = true
                inventories[pid] = [window]
                SystemWindow.existingIDs = [702, 999]
            case .replacementInstance:
                _ = NSRunningApplication(ownedPID: pid, launchDate: Date(timeIntervalSince1970: 2_000))
            case .visibleWindow:
                SystemWindow.snapshot = [SystemWindow(id: 703, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
                SystemWindow.existingIDs = [703, 999]
            }
            DispatchQueue.main.advance(to: forceAt + 0.30)
            expect(signals.isEmpty, "Escalation must leave the short public-API exit grace period")
            DispatchQueue.main.advance(to: forceAt + 0.65)
            if case .none = change {
                expect(signals == [pid], "Only the unchanged, still windowless stalled process may receive the injected signal")
            } else {
                expect(signals.isEmpty, "New AX/CG windows or a replacement process instance must veto the injected signal")
            }
            closing.reset()
        }
    }

    @MainActor private static func forwardedLastCloseAuthorizationPreservesWindowOwnership() {
        enum Scenario { case last, standardSibling, minimizedSibling, finder, customException, siblingBeforeCompletion }
        for (index, scenario) in [Scenario.last, .standardSibling, .minimizedSibling, .finder, .customException, .siblingBeforeCompletion].enumerated() {
            DispatchQueue.main.reset()
            let pid = pid_t(97500 + index)
            let bundle = scenario == .finder ? "com.apple.finder" : "com.allm4.Trio.OwnedForwarding"
            let app = NSRunningApplication(ownedPID: pid, bundleIdentifier: bundle)
            let original = AXUIElement(80), sibling = AXUIElement(81)
            let target = WindowTarget(id: 801, pid: pid, window: original)
            NSWorkspace.shared.frontmostApplication = app
            inventories[pid] = [original]
            SystemWindow.snapshot = [SystemWindow(id: 801, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
            SystemWindow.existingIDs = [801, 999]
            if scenario == .standardSibling || scenario == .minimizedSibling {
                sibling.minimized = scenario == .minimizedSibling
                inventories[pid] = [original, sibling]
                SystemWindow.existingIDs.insert(802)
                if !sibling.minimized { SystemWindow.snapshot.append(SystemWindow(id: 802, pid: pid, layer: 0)) }
            }
            let closing = makeClosing(mayQuitOnLastWindow: { _ in scenario != .customException })
            let expectsAuthorization = scenario == .last || scenario == .siblingBeforeCompletion
            let actionsBefore = performedAXActions
            expect(closing.shouldForwardLastClose(target) == expectsAuthorization,
                   "Only a confirmed single standard window outside Finder/custom exceptions permits forwarding")
            let completedNativeClick = closing.authorizeForwardedLastClose(target)
            expect((completedNativeClick != nil) == expectsAuthorization, "Authorization must match the forwarding decision")
            expect(performedAXActions == actionsBefore, "Preparing native forwarding must not send AXPress")
            if let completedNativeClick {
                if scenario == .siblingBeforeCompletion {
                    inventories[pid] = [sibling]
                    SystemWindow.snapshot = [SystemWindow(id: 802, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
                    SystemWindow.existingIDs = [802, 999]
                    closing.windowOpened(sibling, in: pid)
                } else {
                    // Simulate an already delivered native down/up, not another
                    // AXPress. The authorization closure only confirms closure.
                    inventories[pid] = []
                    SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
                    SystemWindow.existingIDs = [999]
                }
                DispatchQueue.main.advance(to: 0.2)
                expect(app.forceTerminateCalls == 0, "Authorizing alone must not start closing analysis")
                completedNativeClick()
            }
            DispatchQueue.main.advance(to: 6)
            expect(performedAXActions == actionsBefore, "Native completion must never send a second close click or AXPress")
            let expectedForces = scenario == .last ? 1 : 0
            expect(app.terminateCalls == 0 && app.forceTerminateCalls == expectedForces,
                   "Native completion may quit only the confirmed last window, preserving siblings and exceptions")
            closing.reset()
        }
    }

    @MainActor private static func floatingControlLessDialogsRequirePublicGeometryProof() {
        enum Surface { case floating, modal, normalLayer, foreignOwner, withControls }
        for (index, surface) in [Surface.floating, .modal, .normalLayer, .foreignOwner, .withControls].enumerated() {
            DispatchQueue.main.reset()
            let pid = pid_t(97600 + index)
            let app = NSRunningApplication(ownedPID: pid, bundleIdentifier: "com.microsoft.edgemac")
            let original = AXUIElement(90)
            let dialog = AXUIElement(91, subrole: kAXDialogSubrole, hasWindowControls: surface == .withControls)
            dialog.modal = surface == .modal
            let layer = surface == .normalLayer ? 0 : 3
            SystemWindow.floatingEvidence[dialog.id] = SystemWindow.FloatingEvidence(
                owner: surface == .foreignOwner ? pid + 1 : pid, layer: layer, size: CGSize(width: 84, height: 77))
            NSWorkspace.shared.frontmostApplication = app
            inventories[pid] = [original, dialog]
            SystemWindow.snapshot = [SystemWindow(id: 901, pid: pid, layer: 0),
                                     SystemWindow(id: 902, pid: pid, layer: layer),
                                     SystemWindow(id: 999, pid: 97002, layer: 0)]
            SystemWindow.existingIDs = [901, 902, 999]
            let closing = makeClosing(mayQuitOnLastWindow: { _ in true })
            let target = WindowTarget(id: 901, pid: pid, window: original)
            expect(!closing.shouldForwardLastClose(target), "Even a verified floating dialog keeps AXWindows count above one and vetoes HID")
            expect(closing.authorizeForwardedLastClose(target) == nil, "Floating surfaces must not broaden forwarding authorization")
            expect(closing.close(target))
            closing.windowOpened(dialog, in: pid)
            DispatchQueue.main.advance(to: 0.2)
            inventories[pid] = [dialog]
            SystemWindow.snapshot = [SystemWindow(id: 902, pid: pid, layer: layer),
                                     SystemWindow(id: 999, pid: 97002, layer: 0)]
            SystemWindow.existingIDs = [902, 999]
            DispatchQueue.main.advance(to: 0.7)
            expect(app.terminateCalls == 0 && app.forceTerminateCalls == 0,
                   "A dialog still in AXWindows must veto termination, including a nonmodal layer-three surface")
            inventories[pid] = []
            SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
            SystemWindow.existingIDs = [999]
            DispatchQueue.main.advance(to: 4.8)
            let expected = surface == .floating ? 1 : 0
            expect(app.terminateCalls == 0 && app.forceTerminateCalls == expected,
                   "Only a nonmodal, control-less AXDialog independently proven floating for this PID may settle as transient")
            closing.reset()
        }
    }

    @MainActor private static func kernelBirthValidatesIdentityWhenFoundationDateIsUnavailable() {
        for changedKernelBirth in [false, true] {
            DispatchQueue.main.reset()
            let pid: pid_t = changedKernelBirth ? 97701 : 97700
            let app = NSRunningApplication(ownedPID: pid,
                                          launchDate: changedKernelBirth ? Date(timeIntervalSince1970: 1_000) : nil)
            let original = AXUIElement(100)
            let target = WindowTarget(id: 1001, pid: pid, window: original)
            NSWorkspace.shared.frontmostApplication = app
            inventories[pid] = [original]
            SystemWindow.snapshot = [SystemWindow(id: 1001, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
            SystemWindow.existingIDs = [1001, 999]
            let closing = makeClosing(mayQuitOnLastWindow: { _ in true })
            expect(closing.close(target))
            let originalFoundationDate = app.launchDate
            if changedKernelBirth {
                app.kernelBirth = app.kernelBirth! + 1
                expect(NSRunningApplication(processIdentifier: pid) == app && app.launchDate == originalFoundationDate,
                       "The negative case intentionally retains Foundation equality while the kernel birth changes")
            } else {
                expect(app.launchDate == nil, "The positive case must not rely on a Foundation launch date")
            }
            inventories[pid] = []
            SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
            SystemWindow.existingIDs = [999]
            DispatchQueue.main.advance(to: 4.8)
            let expectedForces = changedKernelBirth ? 0 : 1
            expect(app.terminateCalls == 0 && app.forceTerminateCalls == expectedForces,
                   "Only an unchanged captured kernel birth may identify the process, even when Foundation is nil or stale")
            closing.reset()
        }
    }
}
