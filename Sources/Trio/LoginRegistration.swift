import AppKit
import ServiceManagement

/// Service Management records the signed helper's code requirement. Refresh
/// an enabled registration after a local update changes that requirement.
@MainActor enum LoginRegistration {
    static let versionKey = "loginRegisteredBundleVersion"
    static let wantedKey = "startupWanted"
    private(set) static var lastError: String?

    static var service: SMAppService {
        SMAppService.loginItem(identifier: "com.allm4.Trio.LoginHelper")
    }

    private static var legacyAgent: SMAppService {
        SMAppService.agent(plistName: "com.allm4.Trio.login.plist")
    }

    private static func removeLegacyAgent() throws {
        let old = legacyAgent
        if old.status == .enabled || old.status == .requiresApproval { try old.unregister() }
    }

    static func refreshAfterUpdate() {
        let defaults = UserDefaults.standard
        let service = service
        let oldStatus = legacyAgent.status
        if defaults.object(forKey: wantedKey) == nil {
            let previouslyRequested = defaults.string(forKey: versionKey) != nil
            let desired = oldStatus == .enabled || service.status == .enabled ||
                (oldStatus == .requiresApproval && previouslyRequested)
            defaults.set(desired, forKey: wantedKey)
        }
        let wanted = defaults.bool(forKey: wantedKey)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        lastError = nil
        do {
            // Retire only our old agent. Its short-lived helper is independent
            // from the main app, so this never terminates the running Trio UI.
            try removeLegacyAgent()
            guard wanted, !build.isEmpty else { return }
            // An approval request remains a visible pending state. Never open
            // System Settings or repeatedly request approval during startup.
            guard service.status != .requiresApproval else { return }
            if service.status == .enabled {
                guard defaults.string(forKey: versionKey) != build else { return }
                try service.unregister()
            }
            try service.register()
            recordCurrentBuild()
        } catch {
            // Preserve the requested preference, but display the actual new
            // service state rather than pretending registration succeeded.
            lastError = "Não foi possível registrar o início automático: \(error.localizedDescription)"
            NSLog("Trio: login registration refresh failed: %@", error.localizedDescription)
        }
    }

    static func enable() throws {
        UserDefaults.standard.set(true, forKey: wantedKey)
        lastError = nil
        try removeLegacyAgent()
        try service.register()
        recordCurrentBuild()
    }

    static func disable() throws {
        // Persist the user's intent before the OS call, including on failure.
        // A later app update must never silently re-enable a disabled item.
        UserDefaults.standard.set(false, forKey: wantedKey)
        lastError = nil
        try removeLegacyAgent()
        let current = service
        if current.status == .enabled || current.status == .requiresApproval { try current.unregister() }
    }

    static func recordCurrentBuild() {
        UserDefaults.standard.set(true, forKey: wantedKey)
        lastError = nil
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            UserDefaults.standard.set(build, forKey: versionKey)
        }
    }
}
