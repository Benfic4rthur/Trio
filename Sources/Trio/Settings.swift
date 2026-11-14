import AppKit
import ServiceManagement

@MainActor
final class SettingsStore: NSObject {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: "controlsEnabled")
            onChange?()
        }
    }

    var scale: Double {
        didSet {
            let bounded = scale.isFinite ? min(5, max(1, scale)) : 1.5
            if scale != bounded { scale = bounded }
            guard scale != oldValue else { return }
            defaults.set(scale, forKey: "controlScale")
            onChange?()
        }
    }

    var showInMenuBar: Bool {
        didSet {
            guard showInMenuBar != oldValue else { return }
            defaults.set(showInMenuBar, forKey: "showInMenuBar")
            onChange?()
        }
    }

    var keepInDock: Bool {
        didSet {
            guard keepInDock != oldValue else { return }
            defaults.set(keepInDock, forKey: "keepInDock")
            onChange?()
        }
    }

    var autoMaximizeNewWindows: Bool {
        didSet {
            guard autoMaximizeNewWindows != oldValue else { return }
            defaults.set(autoMaximizeNewWindows, forKey: "autoMaximizeNewWindows")
            onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["controlsEnabled": true, "controlScale": 1.5,
                                     "showInMenuBar": false, "keepInDock": false,
                                     "autoMaximizeNewWindows": true])
        enabled = defaults.bool(forKey: "controlsEnabled")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        keepInDock = defaults.bool(forKey: "keepInDock")
        autoMaximizeNewWindows = defaults.bool(forKey: "autoMaximizeNewWindows")
        let savedScale = defaults.double(forKey: "controlScale")
        scale = savedScale.isFinite ? min(5, max(1, savedScale)) : 1.5
        super.init()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: SettingsStore
    private let onHide: () -> Void
    private let onQuit: () -> Void
    private let onPermission: () -> Void
    private let statusLabel = NSTextField(wrappingLabelWithString: "Aguardando verificação da Acessibilidade e da janela ativa…")
    private let scaleLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Iniciar silenciosamente com o macOS", target: nil, action: nil)
    private let menuCheckbox = NSButton(checkboxWithTitle: "Mostrar na barra de menus", target: nil, action: nil)
    private let dockCheckbox = NSButton(checkboxWithTitle: "Manter no Dock ao esconder", target: nil, action: nil)
    private let autoMaximizeCheckbox = NSButton(checkboxWithTitle: "Abrir novas janelas maximizadas", target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: "Abrir Itens de Início…", target: nil, action: nil)
    private let slider: NSSlider
    private let loginService = SMAppService.agent(plistName: "com.allm4.Trio.login.plist")

    init(settings: SettingsStore, onHide: @escaping () -> Void,
         onQuit: @escaping () -> Void, onPermission: @escaping () -> Void) {
        self.settings = settings
        self.onHide = onHide
        self.onQuit = onQuit
        self.onPermission = onPermission
        slider = NSSlider(value: settings.scale, minValue: 1, maxValue: 5, target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 690),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Trio"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TrioSettings")
        super.init(window: window)
        window.delegate = self
        buildContent()
        refreshControls()
        refreshLoginState()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Use init(settings:onHide:onQuit:onPermission:)") }

    func show() {
        refreshControls()
        refreshLoginState()
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateStatus(_ text: String) {
        statusLabel.stringValue = text
        refreshControls()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideInterface()
        return false
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "Trio")
        heading.font = .systemFont(ofSize: 28, weight: .semibold)
        let subtitle = secondary("Controles de janela ao alcance.")
        let header = horizontal([heading, NSView(), subtitle], spacing: 14)

        let sizeTitle = sectionTitle("Tamanho dos controles")
        slider.target = self
        slider.action = #selector(changeScale(_:))
        slider.isContinuous = true
        slider.setAccessibilityLabel("Tamanho dos controles, de uma a cinco vezes o original")
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        scaleLabel.alignment = .right
        scaleLabel.widthAnchor.constraint(equalToConstant: 55).isActive = true
        let sizeHeading = horizontal([sizeTitle, NSView(), scaleLabel], spacing: 14)
        let sliderRow = horizontal([secondary("1×"), slider, secondary("5×")], spacing: 10)
        let sizeExplanation = secondary("O tamanho efetivo se ajusta ao espaço livre da barra. Janelas sem uma área segura mantêm seus controles originais.")
        let greenExplanation = secondary("O verde maximiza na área útil do monitor. Clique novamente para restaurar o tamanho anterior; passe o mouse para organizar a janela.")
        autoMaximizeCheckbox.target = self
        autoMaximizeCheckbox.action = #selector(toggleAutoMaximize(_:))
        autoMaximizeCheckbox.toolTip = "Quando o aplicativo permitir redimensionar. Não afeta alertas nem caixas de diálogo."
        let autoMaximizeExplanation = secondary("Quando o aplicativo permitir redimensionar. Não afeta alertas nem caixas de diálogo.")
        let sizeSection = vertical([sizeHeading, sliderRow, sizeExplanation, greenExplanation,
                                    autoMaximizeCheckbox, autoMaximizeExplanation], spacing: 6)

        let statusTitle = sectionTitle("Estado do Trio")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setAccessibilityLabel("Estado dos controles")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePaused)
        let permissionButton = button("Permitir Acessibilidade…", action: #selector(requestPermission))
        let stateButtons = horizontal([pauseButton, permissionButton, NSView()], spacing: 8)
        let permissionExplanation = secondary("A Acessibilidade permite localizar as janelas e acionar seus controles. A autorização é feita nos Ajustes do Sistema.")
        let stateSection = vertical([statusTitle, statusLabel, stateButtons, permissionExplanation], spacing: 6)

        let sessionTitle = sectionTitle("Sessão e visibilidade")
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin(_:))
        loginStatus.font = .systemFont(ofSize: 11)
        loginStatus.textColor = .secondaryLabelColor
        loginSettingsButton.bezelStyle = .rounded
        loginSettingsButton.controlSize = .small
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginSettings)
        menuCheckbox.target = self
        menuCheckbox.action = #selector(toggleMenuVisibility(_:))
        dockCheckbox.target = self
        dockCheckbox.action = #selector(toggleDockVisibility(_:))
        let sessionExplanation = secondary("Reabra pela pasta Aplicativos ou clique com o botão direito na área dos controles e escolha “Abrir Trio”.")
        let sessionSection = vertical([sessionTitle, loginCheckbox, loginStatus, loginSettingsButton, menuCheckbox, dockCheckbox, sessionExplanation], spacing: 6)

        let divider = NSBox()
        divider.boxType = .separator
        let quitButton = button("Encerrar Trio", action: #selector(quitTrio))
        let hideButton = button("Esconder Trio", action: #selector(hideTrio))
        hideButton.keyEquivalent = "\r"
        let footer = horizontal([quitButton, NSView(), hideButton], spacing: 10)
        let hideExplanation = secondary("Esconder fecha esta interface e mantém os controles funcionando. Encerrar desativa o Trio até a próxima abertura.")

        let root = vertical([header, sizeSection, divider, stateSection, sessionSection, NSView(), hideExplanation, footer], spacing: 10)
        content.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func refreshControls() {
        slider.doubleValue = settings.scale
        scaleLabel.stringValue = String(format: "%.1f×", settings.scale)
        pauseButton.title = settings.enabled ? "Pausar controles" : "Retomar controles"
        menuCheckbox.state = settings.showInMenuBar ? .on : .off
        dockCheckbox.state = settings.keepInDock ? .on : .off
        autoMaximizeCheckbox.state = settings.autoMaximizeNewWindows ? .on : .off
    }

    private func refreshLoginState(error: String? = nil) {
        let status = loginService.status
        loginCheckbox.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        loginSettingsButton.isHidden = status != .requiresApproval && error == nil
        if let error {
            loginStatus.stringValue = error
            loginStatus.textColor = .systemRed
            return
        }
        loginStatus.textColor = .secondaryLabelColor
        switch status {
        case .enabled:
            loginStatus.stringValue = "Início automático ativo, sem abrir as configurações."
        case .requiresApproval:
            loginStatus.stringValue = "Ative o Trio em Itens de Início nos Ajustes do Sistema."
        case .notFound:
            let bundledPlist = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchAgents/com.allm4.Trio.login.plist")
            if FileManager.default.fileExists(atPath: bundledPlist.path) {
                loginStatus.stringValue = "O início automático ainda não está ativo. Ative a opção para solicitar o registro."
            } else {
                loginStatus.stringValue = "O auxiliar de início não foi encontrado nesta instalação."
            }
        case .notRegistered:
            loginStatus.stringValue = "O Trio iniciará quando você abrir o aplicativo."
        @unknown default:
            loginStatus.stringValue = "Consulte os Itens de Início nos Ajustes do Sistema."
        }
    }

    @objc private func changeScale(_ sender: NSSlider) {
        settings.scale = (sender.doubleValue * 10).rounded() / 10
        refreshControls()
    }

    @objc private func togglePaused() {
        settings.enabled.toggle()
        refreshControls()
    }

    @objc private func requestPermission() { onPermission() }

    @objc private func toggleMenuVisibility(_ sender: NSButton) {
        settings.showInMenuBar = sender.state == .on
    }

    @objc private func toggleDockVisibility(_ sender: NSButton) {
        settings.keepInDock = sender.state == .on
    }

    @objc private func toggleAutoMaximize(_ sender: NSButton) {
        settings.autoMaximizeNewWindows = sender.state == .on
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try loginService.register() }
            else { try loginService.unregister() }
            refreshLoginState()
        } catch {
            refreshLoginState(error: "Não foi possível alterar o início automático: \(error.localizedDescription)")
        }
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func hideTrio() { hideInterface() }
    @objc private func quitTrio() { onQuit() }

    private func hideInterface() {
        window?.orderOut(nil)
        onHide()
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }
}
