import AppKit

@MainActor
enum TrioAppIcon {
    /// Keep the running app's temporary Dock icon aligned with its bundle.
    static func apply() {
        guard let url = Bundle.main.url(forResource: "Trio", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}
