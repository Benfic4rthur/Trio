import AppKit

// Disposable compatibility target. It owns no user documents, never quits merely
// because its last window closed, and records close/terminate as distinct events.
final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    let arguments = ProcessInfo.processInfo.arguments
    var logURL: URL {
        if let index = arguments.firstIndex(of: "--log"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("TrioFixture.jsonl")
    }
    private var monitor: Any?

    func record(_ event: String, window: NSWindow? = nil, extra: [String: Any] = [:]) {
        var entry: [String: Any] = ["event": event, "pid": ProcessInfo.processInfo.processIdentifier,
                                    "time": Date().timeIntervalSince1970]
        if let window { entry["window"] = window.windowNumber; entry["title"] = window.title }
        extra.forEach { entry[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys),
              let line = String(data: data, encoding: .utf8) else { return }
        let output = Data((line + "\n").utf8)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: output)
            try? handle.close()
        }
        print(line)
        fflush(stdout)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Deslocar controles de teste", action: #selector(shiftControls), keyEquivalent: "b")
        appMenu.addItem(withTitle: "Encerrar fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(shiftControls),
            name: Notification.Name((Bundle.main.bundleIdentifier ?? "com.allm4.TrioFixture") + ".shiftControls"), object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.record(event.type == .leftMouseDown ? "leftMouseDown" : "rightMouseDown", window: event.window,
                         extra: ["x": event.locationInWindow.x, "y": event.locationInWindow.y])
            return event
        }
        let requestedCount: Int? = arguments.firstIndex(of: "--window-count").flatMap { index in
            arguments.indices.contains(index+1) ? Int(arguments[index+1]) : nil
        }
        let count = requestedCount.map { min(15,max(1,$0)) } ?? (arguments.contains("--two-windows") ? 2 : 1)
        for index in 0..<count { makeWindow(index: index) }
        record("launched", extra: ["customTitlebar": arguments.contains("--custom-titlebar"), "windowCount": windows.count])
        NSApp.activate()
        windows.last?.makeKeyAndOrderFront(nil)
    }

    func makeWindow(index: Int) {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if arguments.contains("--custom-titlebar") { style.insert(.fullSizeContentView) }
        if arguments.contains("--no-resize") { style.remove(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 260 + index * 45, y: 180 + index * 45, width: 680, height: 460),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = arguments.contains("--custom-titlebar") ? "Trio Fixture • Barra personalizada \(index + 1)" : "Trio Fixture • Barra padrão \(index + 1)"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        if arguments.contains("--no-close") { window.standardWindowButton(.closeButton)?.isHidden = true }
        if arguments.contains("--no-buttons") {
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 460))
        content.autoresizingMask = [.width, .height]
        let headline = NSTextField(labelWithString: "Janela de teste do Trio")
        headline.font = .systemFont(ofSize: 24, weight: .semibold)
        headline.translatesAutoresizingMaskIntoConstraints = false
        let body = NSTextField(wrappingLabelWithString: "Sem documentos ou dados pessoais.\n\nFechar a última janela mantém este processo ativo. Se o processo encerrar após um clique vermelho, o evento applicationWillTerminate ficará registrado.\n\nUse esta janela para testar minimizar, maximizar, restaurar, mover e redimensionar.")
        body.font = .systemFont(ofSize: 14)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headline)
        content.addSubview(body)
        NSLayoutConstraint.activate([
            headline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            headline.topAnchor.constraint(equalTo: content.topAnchor, constant: 84),
            body.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            body.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 16)
        ])
        if arguments.contains("--custom-titlebar") {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            let tools = NSButton(title: "Ferramenta próxima", target: self, action: #selector(toolClicked(_:)))
            tools.identifier = NSUserInterfaceItemIdentifier("fixture-nearby-tool")
            tools.setAccessibilityLabel("Ferramenta próxima aos controles")
            tools.bezelStyle = .inline
            tools.frame = NSRect(x: 98, y: 460 - 30, width: 140, height: 24)
            tools.autoresizingMask = [.minYMargin]
            content.addSubview(tools)
        }
        window.contentView = content
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        record("windowCreated", window: window)
    }

    @objc func toolClicked(_ sender: NSButton) { record("nearbyToolClicked", window: sender.window) }
    @objc func shiftControls() {
        for window in windows {
            let before = window.frame
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                button.setFrameOrigin(NSPoint(x: button.frame.minX, y: button.frame.minY - 4))
                NSAccessibility.post(element: button, notification: .moved)
            }
            NSAccessibility.post(element: window, notification: .layoutChanged)
            record("nativeControlsShifted", window: window,
                   extra: ["outerFrameUnchanged": NSEqualRects(before, window.frame)])
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        record("applicationShouldTerminate")
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { record("applicationWillTerminate") }
    func windowWillClose(_ notification: Notification) { record("windowWillClose", window: notification.object as? NSWindow) }
    func windowDidMiniaturize(_ notification: Notification) { record("windowDidMiniaturize", window: notification.object as? NSWindow) }
    func windowDidDeminiaturize(_ notification: Notification) { record("windowDidDeminiaturize", window: notification.object as? NSWindow) }
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        record("windowDidResize", window: window, extra: ["x": window.frame.origin.x, "y": window.frame.origin.y,
                                                        "width": window.frame.width, "height": window.frame.height])
    }
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        record("windowDidMove", window: window, extra: ["x": window.frame.origin.x, "y": window.frame.origin.y])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
