import AppKit
import ApplicationServices
import Darwin

private let reopenNotification = Notification.Name("com.allm4.Trio.showSettings")

/// LaunchServices reuses the running app; this also covers a directly launched binary.
private final class InstanceLease {
    private let descriptor: Int32

    init?() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        descriptor = Darwin.open(support.appendingPathComponent("instance.lock").path,
                                 O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        _ = fchmod(descriptor, mode_t(0o600))
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lease: InstanceLease
    private let settings = SettingsStore()
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var statusText = "Verificando a Acessibilidade e a janela ativa…"
    private var launched = false
    private var stopped = false
    private lazy var engine = TrioEngine(settings: settings, onStatus: { [weak self] text in
        if CommandLine.arguments.contains("--diagnostics") { FileHandle.standardError.write(Data(("[Trio status] " + text + "\n").utf8)) }
        self?.statusText = text
        self?.settingsController?.updateStatus(text)
    }, onOpen: { [weak self] in self?.showSettings() })

    init(lease: InstanceLease) {
        self.lease = lease
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationMenu()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveReopen),
                                                            name: reopenNotification,
                                                            object: NSUserName())
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.updatePresence()
            self.engine.refresh()
        }
        launched = true
        updatePresence()
        engine.start()
        if !CommandLine.arguments.contains("--background") { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard launched else { return }
        // Returning from System Settings rechecks authorization without a polling timer.
        engine.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { stopEngine() }

    @objc private func receiveReopen(_ notification: Notification) { showSettings() }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings,
                onHide: { [weak self] in self?.hideSettings() },
                onQuit: { [weak self] in self?.quitTrio() },
                onPermission: { [weak self] in self?.requestAccessibility() })
        }
        settingsController?.updateStatus(statusText)
        settingsController?.show()
        updatePresence()
    }

    @objc private func hideSettings() {
        settingsController?.window?.orderOut(nil)
        updatePresence()
    }

    @objc private func togglePaused() {
        settings.enabled.toggle()
        settingsController?.updateStatus(statusText)
    }

    @objc private func quitTrio() {
        stopEngine()
        NSApp.terminate(nil)
    }

    private func stopEngine() {
        guard !stopped else { return }
        stopped = true
        engine.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        engine.refresh()
    }

    private func updatePresence() {
        let settingsVisible = settingsController?.window?.isVisible == true
        NSApp.setActivationPolicy(settingsVisible || settings.keepInDock ? .regular : .accessory)
        if settings.showInMenuBar {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                statusItem?.button?.image = TrioBrand.menuIcon()
                statusItem?.button?.toolTip = "Trio"
            }
            let menu = NSMenu()
            menu.addItem(menuItem("Abrir Trio", #selector(showSettings)))
            menu.addItem(menuItem(settings.enabled ? "Pausar controles" : "Retomar controles", #selector(togglePaused)))
            menu.addItem(menuItem("Esconder Trio", #selector(hideSettings)))
            menu.addItem(.separator())
            menu.addItem(menuItem("Encerrar Trio", #selector(quitTrio)))
            statusItem?.menu = menu
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Trio")
        appMenu.addItem(menuItem("Abrir Trio", #selector(showSettings)))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Esconder Trio", #selector(hideSettings), key: "h"))
        appMenu.addItem(menuItem("Encerrar Trio", #selector(quitTrio), key: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }
}

MainActor.assumeIsolated {
    guard let lease = InstanceLease() else {
        if !CommandLine.arguments.contains("--background") {
            DistributedNotificationCenter.default().postNotificationName(reopenNotification,
                object: NSUserName(), userInfo: nil, deliverImmediately: true)
        }
        exit(EXIT_SUCCESS)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(lease: lease)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
