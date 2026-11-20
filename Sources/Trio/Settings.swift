import AppKit
import ServiceManagement
import UniformTypeIdentifiers

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

    var autoMaximizeExcludedBundleIDs: [String] {
        didSet {
            guard autoMaximizeExcludedBundleIDs != oldValue else { return }
            defaults.set(autoMaximizeExcludedBundleIDs, forKey: "autoMaximizeExcludedBundleIDs")
            onChange?()
        }
    }

    static let finderBundleID = "com.apple.finder"
    var quitExcludedBundleIDs: [String] {
        didSet {
            quitExcludedBundleIDs = Self.normalizedQuitExceptions(quitExcludedBundleIDs)
            guard quitExcludedBundleIDs != oldValue else { return }
            defaults.set(quitExcludedBundleIDs, forKey: "quitExcludedBundleIDs")
            onChange?()
        }
    }

    private static func normalizedQuitExceptions(_ identifiers: [String]) -> [String] {
        var result = [finderBundleID]
        for identifier in identifiers where !identifier.isEmpty && !result.contains(identifier) { result.append(identifier) }
        return result
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["controlsEnabled": true, "controlScale": 1.5,
                                     "showInMenuBar": false, "keepInDock": false,
                                     "autoMaximizeNewWindows": true,
                                     "quitExcludedBundleIDs": [SettingsStore.finderBundleID],
                                     "autoMaximizeExcludedBundleIDs": ["com.apple.ActivityMonitor", "com.apple.Terminal"]])
        enabled = defaults.bool(forKey: "controlsEnabled")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        keepInDock = defaults.bool(forKey: "keepInDock")
        autoMaximizeNewWindows = defaults.bool(forKey: "autoMaximizeNewWindows")
        autoMaximizeExcludedBundleIDs = defaults.stringArray(forKey: "autoMaximizeExcludedBundleIDs") ?? []
        quitExcludedBundleIDs = Self.normalizedQuitExceptions(defaults.stringArray(forKey: "quitExcludedBundleIDs") ?? [])
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
    private let autoMaximizeCheckbox = NSButton(checkboxWithTitle: "Maximizar novas janelas grandes", target: nil, action: nil)
    private let exclusionsSummary = NSTextField(wrappingLabelWithString: "")
    private let quitExclusionsSummary = NSTextField(wrappingLabelWithString: "")
    private var summarizedExclusions: [String]?
    private var exceptionsController: AutoMaximizeExceptionsController?
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: "Abrir Itens de Início…", target: nil, action: nil)
    private let slider: NSSlider
    private let loginService = LoginRegistration.service

    init(settings: SettingsStore, onHide: @escaping () -> Void,
         onQuit: @escaping () -> Void, onPermission: @escaping () -> Void) {
        self.settings = settings
        self.onHide = onHide
        self.onQuit = onQuit
        self.onPermission = onPermission
        slider = NSSlider(value: settings.scale, minValue: 1, maxValue: 5, target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 780),
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
        let redExplanation = secondary("O vermelho fecha esta janela e encerra o app ao fechar a última. O Finder continua aberto. Se após 5 segundos o app ainda estiver aberto sem janelas, o Trio força o encerramento.")
        let quitExceptionsButton = button("Escolher apps…", action: #selector(showQuitExceptions))
        let quitExceptionsRow = horizontal([secondary("Manter abertos ao fechar a última janela"), NSView(), quitExceptionsButton], spacing: 8)
        quitExclusionsSummary.font = .systemFont(ofSize: 11)
        quitExclusionsSummary.textColor = .secondaryLabelColor
        autoMaximizeCheckbox.target = self
        autoMaximizeCheckbox.action = #selector(toggleAutoMaximize(_:))
        autoMaximizeCheckbox.toolTip = "Só amplia janelas principais grandes. Janelas pequenas, auxiliares e aplicativos nas exceções mantêm o tamanho de abertura."
        let autoMaximizeExplanation = secondary("Janelas pequenas, auxiliares e apps nas exceções mantêm seu tamanho. Só janelas principais grandes e redimensionáveis são ampliadas.")
        let exclusionsButton = button("Exceções…", action: #selector(showAutoMaximizeExceptions))
        let autoMaximizeRow = horizontal([autoMaximizeCheckbox, NSView(), exclusionsButton], spacing: 8)
        exclusionsSummary.font = .systemFont(ofSize: 11)
        exclusionsSummary.textColor = .secondaryLabelColor
        let sizeSection = vertical([sizeHeading, sliderRow, sizeExplanation, greenExplanation, redExplanation,
                                    quitExceptionsRow, quitExclusionsSummary,
                                    autoMaximizeRow, autoMaximizeExplanation, exclusionsSummary], spacing: 6)

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
        let quitNames = settings.quitExcludedBundleIDs.prefix(3).map { AutoMaximizeExceptionsController.appName(for: $0) }
        quitExclusionsSummary.stringValue = quitNames.joined(separator: ", ") +
            (settings.quitExcludedBundleIDs.count > 3 ? " e mais \(settings.quitExcludedBundleIDs.count - 3)." : ".")
        if summarizedExclusions != settings.autoMaximizeExcludedBundleIDs {
            let identifiers = settings.autoMaximizeExcludedBundleIDs
            let names = identifiers.prefix(3).map { AutoMaximizeExceptionsController.appName(for: $0) }
            exclusionsSummary.stringValue = identifiers.isEmpty ? "Nenhum aplicativo nas exceções." :
                "Exceções: " + names.joined(separator: ", ") + (identifiers.count > 3 ? " e mais \(identifiers.count-3)." : ".")
            summarizedExclusions = identifiers
        }
    }

    private func refreshLoginState(error: String? = nil) {
        let status = loginService.status
        loginCheckbox.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        loginSettingsButton.isHidden = status != .requiresApproval && error == nil
        if let error = error ?? LoginRegistration.lastError {
            loginStatus.stringValue = error
            loginStatus.textColor = .systemRed
            return
        }
        loginStatus.textColor = .secondaryLabelColor
        switch status {
        case .enabled:
            loginStatus.stringValue = "Início automático registrado, sem abrir as configurações."
        case .requiresApproval:
            loginStatus.stringValue = "Ative o Trio em Itens de Início nos Ajustes do Sistema."
        case .notFound:
            let helperInfo = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LoginItems/TrioLoginHelper.app/Contents/Info.plist")
            if FileManager.default.fileExists(atPath: helperInfo.path) {
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

    @objc private func showAutoMaximizeExceptions() {
        guard let window, window.attachedSheet == nil else { return }
        let editor = AutoMaximizeExceptionsController(settings: settings) { [weak self] in self?.refreshControls() }
        exceptionsController = editor
        editor.show(asSheetOf: window)
    }

    @objc private func showQuitExceptions() {
        guard let window, window.attachedSheet == nil else { return }
        let editor = AutoMaximizeExceptionsController(settings: settings, kind: .quit) { [weak self] in self?.refreshControls() }
        exceptionsController = editor
        editor.show(asSheetOf: window)
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try LoginRegistration.enable() }
            else { try LoginRegistration.disable() }
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

@MainActor
private final class AutoMaximizeExceptionsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
private final class AutoMaximizeExceptionsController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Kind { case autoMaximize, quit }
    private let settings: SettingsStore
    private let kind: Kind
    private let onChange: () -> Void
    private let table = NSTableView()
    private var identifiers: [String] {
        get { kind == .quit ? settings.quitExcludedBundleIDs : settings.autoMaximizeExcludedBundleIDs }
        set {
            if kind == .quit { settings.quitExcludedBundleIDs = newValue }
            else { settings.autoMaximizeExcludedBundleIDs = newValue }
        }
    }

    init(settings: SettingsStore, kind: Kind = .autoMaximize, onChange: @escaping () -> Void) {
        self.settings = settings
        self.kind = kind
        self.onChange = onChange
        let sheet = AutoMaximizeExceptionsWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 390),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheet.title = kind == .quit ? "Manter aplicativos abertos" : "Exceções da maximização"
        sheet.isReleasedWhenClosed = false
        super.init(window: sheet)
        sheet.delegate = self
        let content = sheet.contentView!
        let explanation = NSTextField(wrappingLabelWithString: kind == .quit ?
            "Ao fechar a última janela, estes aplicativos continuam abertos. O Finder permanece sempre nesta lista. Forçar encerramento continua sendo uma ação explícita para o aplicativo inteiro." :
            "Novas janelas destes aplicativos mantêm o tamanho escolhido por eles. Você continua podendo usar o botão verde do Trio.")
        explanation.font = .systemFont(ofSize: 13)
        let application = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        application.width = 385
        let remove = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remove"))
        remove.width = 95
        table.addTableColumn(application); table.addTableColumn(remove)
        table.frame = NSRect(x: 0, y: 0, width: 500, height: 270)
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.rowHeight = 49
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.delegate = self; table.dataSource = self
        table.selectionHighlightStyle = .none
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        let add = NSButton(title: "Adicionar app…", target: self, action: #selector(addApplication))
        add.bezelStyle = .rounded
        let done = NSButton(title: "Concluído", target: self, action: #selector(closeSheet))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        let footer = NSStackView(views: [add, NSView(), done])
        footer.orientation = .horizontal; footer.spacing = 8
        for view in [explanation, scroll, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            explanation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            explanation.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: explanation.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 15),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -15),
            footer.leadingAnchor.constraint(equalTo: explanation.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(settings:onChange:)") }
    func show(asSheetOf parent: NSWindow) { table.reloadData(); if let window { parent.beginSheet(window) } }
    func numberOfRows(in tableView: NSTableView) -> Int { identifiers.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard identifiers.indices.contains(row) else { return nil }
        if tableColumn?.identifier.rawValue == "remove" {
            let fixed = kind == .quit && identifiers[row] == SettingsStore.finderBundleID
            let button = NSButton(title: fixed ? "Sempre aberto" : "Remover", target: self, action: #selector(removeApplication(_:)))
            button.tag = row; button.bezelStyle = .rounded; button.controlSize = .small
            button.isEnabled = !fixed
            return button
        }
        let id = identifiers[row]
        let name = NSTextField(labelWithString: Self.appName(for: id))
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let identifier = NSTextField(labelWithString: id)
        identifier.font = .systemFont(ofSize: 11); identifier.textColor = .secondaryLabelColor
        identifier.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [name, identifier])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        return stack
    }

    static func appName(for identifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        }
        switch identifier {
        case SettingsStore.finderBundleID: return "Finder"
        case "com.apple.ActivityMonitor": return "Monitor de Atividade"
        case "com.apple.Terminal": return "Terminal"
        default: return identifier
        }
    }

    @objc private func removeApplication(_ sender: NSButton) {
        guard identifiers.indices.contains(sender.tag),
              !(kind == .quit && identifiers[sender.tag] == SettingsStore.finderBundleID) else { return }
        identifiers.remove(at: sender.tag)
        table.reloadData(); onChange()
    }

    @objc private func addApplication() {
        guard let window else { return }
        let chooser = NSOpenPanel()
        chooser.title = "Adicionar uma exceção"
        chooser.prompt = "Adicionar"
        chooser.allowedContentTypes = [.application]
        chooser.canChooseDirectories = false; chooser.canChooseFiles = true
        chooser.treatsFilePackagesAsDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        chooser.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = chooser.url else { return }
            guard let id = Bundle(url: url)?.bundleIdentifier,
                  id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else {
                let alert = NSAlert()
                alert.messageText = "Não foi possível identificar esse aplicativo."
                alert.informativeText = "Escolha um aplicativo macOS válido."
                alert.beginSheetModal(for: window)
                return
            }
            if !self.identifiers.contains(id) {
                self.identifiers.append(id)
                self.table.reloadData(); self.onChange()
            }
        }
    }

    override func cancelOperation(_ sender: Any?) { closeSheet() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeSheet(); return false }
    @objc private func closeSheet() {
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        onChange()
    }
}
