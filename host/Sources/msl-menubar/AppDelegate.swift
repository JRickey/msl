import AppKit
import Foundation
import MSLCore

/// Menu-bar-only app delegate. Owns the status item and the install service and
/// wires Finder's double-click `.msl` opens into the same in-process install the
/// CLI drives. Never touches the daemon flock: it is a pure client.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let home = MSLHome.resolve()
    private var statusController: StatusController?
    private var installer: InstallService?

    /// Build the status item and install service before the run loop delivers
    /// any open events, so a launch-time double-click finds them ready.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let installer = InstallService(home: home)
        self.installer = installer
        self.statusController = StatusController(home: home, installer: installer)
        Notifier.requestAuthorization()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let enabled = await FSKitAction.status()
            guard !enabled else { return }
            switch await FSKitAction.enable() {
            case .ready:
                break
            case .restartRequired:
                Notifier.postDaemon(
                    title: "Finder Integration enabled",
                    message: "Restart your Mac before Finder mounts are available.")
            case .failed(let error):
                Notifier.postDaemon(title: "Finder Integration setup failed", message: error)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let installer else { return }
        assert(!urls.isEmpty, "open delivered no urls")
        for url in urls where url.isFileURL {  // bounded: Finder selection
            installer.requestInstall(url: url)
        }
    }
}
