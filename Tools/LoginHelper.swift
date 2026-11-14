import AppKit
import Darwin

/// A short-lived launchd job opens the main app outside the job's lifetime.
/// Unregistering this agent therefore does not terminate the running Trio UI.
@main
struct TrioLoginHelper {
    @MainActor
    static func main() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let applicationURL = executable.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard applicationURL.pathExtension == "app",
              let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == "com.allm4.Trio",
              let mainExecutable = bundle.executableURL,
              mainExecutable.lastPathComponent == "Trio",
              FileManager.default.isExecutableFile(atPath: mainExecutable.path) else {
            exit(EX_CONFIG)
        }

        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.allm4.Trio")
            .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
        guard !alreadyRunning else { exit(EXIT_SUCCESS) }

        NSApplication.shared.setActivationPolicy(.prohibited)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--background"]
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            exit(error == nil && application != nil ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        // Bound the launch request. This is not an ongoing background service.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(EXIT_FAILURE) }
        RunLoop.main.run()
    }
}
