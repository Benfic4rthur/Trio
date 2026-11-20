import AppKit
import Foundation

// Standalone owned-suite check, deliberately outside the TrioCore test target:
// swiftc -swift-version 5 Sources/Trio/Settings.swift Sources/Trio/LoginRegistration.swift Tests/SettingsPersistenceTests.swift -o /tmp/trio-settings-persistence-test
@main
struct SettingsPersistenceTests {
    @MainActor static func main() {
        let suite = "com.allm4.Trio.Tests.Settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot create isolated suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        // register(defaults:) is process-wide fallback state, even for a named
        // suite. Compare the app's persisted domain rather than fallback reads.
        let before = UserDefaults.standard.persistentDomain(forName: "com.allm4.Trio") ?? [:]
        let store = SettingsStore(defaults: defaults)
        precondition(store.autoMaximizeExcludedBundleIDs == ["com.apple.ActivityMonitor", "com.apple.Terminal"])
        precondition(store.quitExcludedBundleIDs == ["com.apple.finder"])
        var changes = 0
        store.onChange = { changes += 1 }
        store.autoMaximizeExcludedBundleIDs = []
        store.quitExcludedBundleIDs.append("com.fixture.KeepOpen")
        precondition(changes == 2)
        let reloaded = SettingsStore(defaults: defaults)
        precondition(reloaded.autoMaximizeExcludedBundleIDs.isEmpty)
        precondition(reloaded.quitExcludedBundleIDs == ["com.apple.finder", "com.fixture.KeepOpen"])
        reloaded.quitExcludedBundleIDs = []
        precondition(reloaded.quitExcludedBundleIDs == ["com.apple.finder"])
        precondition(defaults.stringArray(forKey: "quitExcludedBundleIDs") == ["com.apple.finder"])
        reloaded.quitExcludedBundleIDs = ["com.fixture.KeepOpen", "com.fixture.KeepOpen", "com.apple.finder"]
        precondition(reloaded.quitExcludedBundleIDs == ["com.apple.finder", "com.fixture.KeepOpen"])
        reloaded.quitExcludedBundleIDs.removeAll { $0 == "com.apple.finder" }
        precondition(reloaded.quitExcludedBundleIDs.first == "com.apple.finder")
        precondition(reloaded.autoMaximizeExcludedBundleIDs.isEmpty)
        defaults.set(["com.fixture.Raw"], forKey: "quitExcludedBundleIDs")
        precondition(SettingsStore(defaults: defaults).quitExcludedBundleIDs == ["com.apple.finder", "com.fixture.Raw"])
        let after = UserDefaults.standard.persistentDomain(forName: "com.allm4.Trio") ?? [:]
        precondition(NSDictionary(dictionary: before).isEqual(to: after), "Personal preferences must remain untouched")
        print("PASS: isolated persistence, independent exception lists, fixed Finder, onChange and unchanged personal preferences")
    }
}
