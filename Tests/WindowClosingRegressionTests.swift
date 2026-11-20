import AppKit
import ApplicationServices

// Run: swiftc -swift-version 5 Sources/Trio/WindowClosing.swift Tests/WindowClosingRegressionTests.swift -o /tmp/trio-closing-test && /tmp/trio-closing-test
// Platform shims keep the production coordinator unchanged and make time,
// AX inventory and process termination fully deterministic. No IPC is sent.
final class FakeElement {
    let id: Int
    init(_ id: Int) { self.id = id }
}
typealias AXUIElement = FakeElement
@MainActor private var inventories: [pid_t: [AXUIElement]] = [:]
@MainActor private var applicationElements: [pid_t: AXUIElement] = [:]
func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ seconds: Float) -> AXError { .success }
func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError { .success }
@MainActor enum AX {
    static func value(_ element: ApplicationServices.AXUIElement, _ attribute: String) -> Any? {
        attribute == kAXWindowsAttribute ? inventories[NSWorkspace.shared.frontmostApplication!.processIdentifier] : nil
    }
    static func value(_ element: AXUIElement, _ attribute: String) -> Any? {
        if attribute == kAXWindowsAttribute, let pid = applicationElements.first(where: { $0.value === element })?.key { return inventories[pid] }
        if attribute == kAXChildrenAttribute { return [AXUIElement]() }
        return nil
    }
    static func same(_ first: AXUIElement, _ second: AXUIElement) -> Bool { first === second }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        attribute == kAXSubroleAttribute ? kAXStandardWindowSubrole : nil
    }
}

private final class FakeApplicationState {
    let pid: pid_t
    let bundleIdentifier: String
    var isTerminated = false, isHidden = false
    var terminateCalls = 0, forceTerminateCalls = 0
    init(pid: pid_t, bundleIdentifier: String) { self.pid = pid; self.bundleIdentifier = bundleIdentifier }
}
@MainActor struct NSRunningApplication {
    private static var registry: [pid_t: FakeApplicationState] = [:]
    private let state: FakeApplicationState
    var processIdentifier: pid_t { state.pid }
    var bundleIdentifier: String? { state.bundleIdentifier }
    var activationPolicy: NSApplication.ActivationPolicy { .regular }
    var isTerminated: Bool { state.isTerminated }
    var isHidden: Bool {
        get { state.isHidden }
        nonmutating set { state.isHidden = newValue }
    }
    var terminateCalls: Int { state.terminateCalls }
    var forceTerminateCalls: Int { state.forceTerminateCalls }
    init(ownedPID: pid_t, bundleIdentifier: String = "com.allm4.Trio.OwnedRegression") {
        state = FakeApplicationState(pid: ownedPID, bundleIdentifier: bundleIdentifier)
        Self.registry[ownedPID] = state
    }
    init?(processIdentifier: pid_t) {
        guard let stored = Self.registry[processIdentifier] else { return nil }
        state = stored
    }
    func terminate() -> Bool { state.terminateCalls += 1; state.isTerminated = true; return true }
    func forceTerminate() -> Bool { state.forceTerminateCalls += 1; state.isTerminated = true; return true }
    static func == (first: NSRunningApplication, second: NSRunningApplication) -> Bool { first.state === second.state }
    static func == (first: NSRunningApplication?, second: NSRunningApplication) -> Bool { first.map { $0.state === second.state } ?? false }
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication: NSRunningApplication?
}
struct SystemWindow {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    @MainActor static var snapshot: [SystemWindow] = []
    @MainActor static var existingIDs: Set<CGWindowID> = []
    @MainActor static func visible() -> [SystemWindow] { snapshot }
    @MainActor static func noLongerExists(_ id: CGWindowID) -> Bool { !existingIDs.contains(id) }
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

@main struct WindowClosingRegressionTests {
    @MainActor static func main() {
        earlyDestructionAndDelayedCleanup()
        anotherMinimizedWindowCancelsPermanently()
        edgeFallbackRequiresDisappearedWindowID()
        print("PASS: delayed original close, permanent minimized-window veto and Edge CG-ID fallback; no apps opened or real AX actions")
    }

    @MainActor private static func earlyDestructionAndDelayedCleanup() {
        DispatchQueue.main.reset()
        let pid: pid_t = 97001
        let app = NSRunningApplication(ownedPID: pid)
        let window = AXUIElement(1)
        applicationElements[pid] = AXUIElement(3)
        inventories[pid] = [window]
        NSWorkspace.shared.frontmostApplication = app
        SystemWindow.snapshot = [SystemWindow(id: 101, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [101, 999]
        let closing = WindowClosing(mayQuitOnLastWindow: { _ in true })
        expect(closing.close(WindowTarget(id: 101, pid: pid, window: window)))
        DispatchQueue.main.advance(to: 0.01)
        closing.windowDestroyed(window)
        // Destruction was announced, but AX and the compositor still retain it.
        DispatchQueue.main.advance(to: 0.46)
        expect(app.terminateCalls == 0)
        DispatchQueue.main.advance(to: 0.70)
        inventories[pid] = []
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [999]
        DispatchQueue.main.advance(to: 4.0)
        expect(app.terminateCalls == 1, "An early AX destruction must not expire the pending close")
        expect(app.forceTerminateCalls == 0)
        DispatchQueue.main.advance(to: 5.5)
        expect(app.terminateCalls == 1, "Stale surveys must not send another quit")
    }

    @MainActor private static func anotherMinimizedWindowCancelsPermanently() {
        DispatchQueue.main.reset()
        let pid: pid_t = 97003
        let app = NSRunningApplication(ownedPID: pid)
        let original = AXUIElement(10), minimized = AXUIElement(11)
        applicationElements[pid] = AXUIElement(12)
        inventories[pid] = [original]
        NSWorkspace.shared.frontmostApplication = app
        SystemWindow.snapshot = [SystemWindow(id: 201, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [201, 999]
        let closing = WindowClosing(mayQuitOnLastWindow: { _ in true })
        expect(closing.close(WindowTarget(id: 201, pid: pid, window: original)))
        DispatchQueue.main.advance(to: 0.01)
        closing.windowDestroyed(original)
        inventories[pid] = [minimized]
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [202, 999]
        DispatchQueue.main.advance(to: 0.7)
        expect(app.terminateCalls == 0, "Another minimized AX window must veto quitting even when CG has none visible")
        inventories[pid] = []
        SystemWindow.existingIDs = [999]
        closing.windowDestroyed(minimized)
        DispatchQueue.main.advance(to: 6)
        expect(app.terminateCalls == 0 && app.forceTerminateCalls == 0,
               "Discovering another window must permanently cancel the earlier last-window authorization")
    }

    @MainActor private static func edgeFallbackRequiresDisappearedWindowID() {
        DispatchQueue.main.reset()
        let pid: pid_t = 97004
        let app = NSRunningApplication(ownedPID: pid, bundleIdentifier: "com.microsoft.edgemac")
        let window = AXUIElement(20)
        applicationElements[pid] = AXUIElement(21)
        inventories[pid] = [window]
        NSWorkspace.shared.frontmostApplication = app
        SystemWindow.snapshot = [SystemWindow(id: 301, pid: pid, layer: 0), SystemWindow(id: 999, pid: 97002, layer: 0)]
        SystemWindow.existingIDs = [301, 999]
        let closing = WindowClosing(mayQuitOnLastWindow: { _ in true })
        closing.observeBrowserWindow(WindowTarget(id: 301, pid: pid, window: window))
        inventories[pid] = []
        SystemWindow.snapshot = [SystemWindow(id: 999, pid: 97002, layer: 0)]
        closing.browserWindowMayHaveClosed(in: pid)
        expect(app.terminateCalls == 0, "An empty AX inventory alone cannot prove that the observed CG window closed")
        SystemWindow.existingIDs = [999]
        closing.browserWindowMayHaveClosed(in: pid)
        DispatchQueue.main.advance(to: 2)
        expect(app.terminateCalls == 1 && app.forceTerminateCalls == 0,
               "A disappeared observed Edge window plus empty AX/visible inventories should request one normal quit")
    }
}
