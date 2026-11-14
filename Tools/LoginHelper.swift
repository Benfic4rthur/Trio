import AppKit
import Darwin
import MachO

/// A short-lived launchd job opens the main app outside the job's lifetime.
/// Unregistering this agent therefore does not terminate the running Trio UI.
@main
struct TrioLoginHelper {
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[TrioLoginHelper] " + message + "\n").utf8))
    }

    private static func mainApplication(containing executable: URL) -> (URL, URL)? {
        var directory = executable.deletingLastPathComponent()
        // Skip the helper's own .app and find only the enclosing Trio bundle.
        for _ in 0..<10 {
            if directory.pathExtension == "app",
               let data = try? Data(contentsOf: directory.appendingPathComponent("Contents/Info.plist")),
               let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
               info["CFBundleIdentifier"] as? String == "com.allm4.Trio",
               info["CFBundleExecutable"] as? String == "Trio" {
                let main = directory.appendingPathComponent("Contents/MacOS/Trio")
                if FileManager.default.isExecutableFile(atPath: main.path) { return (directory, main) }
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    @MainActor
    static func main() {
        // launchd may supply only "TrioLoginHelper" as argv[0]. dyld's public
        // executable-path API resolves the actual running image independently.
        var pathSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &pathSize)
        guard pathSize > 0 else { log("dyld did not return an executable path"); exit(EX_CONFIG) }
        var pathBuffer = [CChar](repeating: 0, count: Int(pathSize))
        guard _NSGetExecutablePath(&pathBuffer, &pathSize) == 0 else { log("Cannot read the executable path"); exit(EX_CONFIG) }
        let executable = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath()
        // Bundle's process-global caches can associate this helper executable
        // with its enclosing app. Read the app's declared entry point directly.
        guard executable.lastPathComponent == "TrioLoginHelper",
              let (applicationURL, mainExecutable) = mainApplication(containing: executable) else {
            log("Cannot locate the enclosing com.allm4.Trio bundle from \(executable.path)")
            exit(EX_CONFIG)
        }

        // Read-only diagnostic for packaging tests; never starts the main app.
        if CommandLine.arguments.contains("--validate-only") {
            let report = ["argv0": CommandLine.arguments[0], "helperExecutable": executable.path,
                          "application": applicationURL.path, "mainExecutable": mainExecutable.path,
                          "bundleIdentifier": "com.allm4.Trio", "processBundleIdentifier": Bundle.main.bundleIdentifier ?? "none",
                          "launchPerformed": "false"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            }
            exit(EXIT_SUCCESS)
        }

        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.allm4.Trio")
            .contains {
                $0.processIdentifier != getpid() && !$0.isTerminated &&
                $0.executableURL?.lastPathComponent == "Trio"
            }
        guard !alreadyRunning else { log("Main app is already running; no launch needed"); exit(EXIT_SUCCESS) }

        NSApplication.shared.setActivationPolicy(.prohibited)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--background"]
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            if let error {
                let detail = error as NSError
                log("Launch failed: domain=\(detail.domain) code=\(detail.code) \(detail.localizedDescription)")
            }
            if let application { log("Main app launch returned pid=\(application.processIdentifier), bundle=\(application.bundleIdentifier ?? "none")") }
            if application == nil && error == nil { log("Launch returned neither an application nor an error") }
            exit(error == nil && application != nil ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        // Bound the launch request. This is not an ongoing background service.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { log("Main app launch timed out"); exit(EXIT_FAILURE) }
        RunLoop.main.run()
    }
}
