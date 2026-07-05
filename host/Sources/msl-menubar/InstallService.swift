import AppKit
import Foundation
import MSLCore
import MSLMenuBarCore

/// Coordinates double-click installs on the main actor: confirm, admit to the
/// bounded queue, run one at a time off-main via `InstallRunner`, drive the
/// progress panel, and notify on completion.
@MainActor
final class InstallService {
    private let home: MSLHome
    private var queue = InstallQueue(capacity: 8)
    private let progress = ProgressPanel()

    init(home: MSLHome) {
        self.home = home
    }

    /// Confirm with the user, then admit the bundle to the install queue.
    func requestInstall(url: URL) {
        assert(url.isFileURL, "install url must be a file url")
        guard confirm(url: url) else { return }
        switch queue.submit(url) {
        case .started:
            progress.show(message: "Installing \(url.lastPathComponent)…")
            run(url)
        case .queued:
            progress.show(message: "Queued \(url.lastPathComponent)…")
        case .dropped:
            warnFull(url: url)
        }
    }

    private func run(_ url: URL) {
        let home = self.home
        Task { @MainActor [weak self] in
            let outcome = await InstallRunner.run(home: home, bundlePath: url.path)
            self?.finish(url: url, outcome: outcome)
        }
    }

    private func finish(url: URL, outcome: InstallOutcome) {
        Notifier.postInstall(result: outcome, url: url)
        if let next = queue.complete() {
            progress.show(message: "Installing \(next.lastPathComponent)…")
            run(next)
        } else {
            progress.hide()
        }
    }

    private func confirm(url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install '\(url.lastPathComponent)' as a new distro?"
        alert.informativeText = "msl will build a distro image from this bundle."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func warnFull(url: URL) {
        assert(url.isFileURL, "warned url must be a file url")
        let alert = NSAlert()
        alert.messageText = "Too many installs queued"
        alert.informativeText =
            "'\(url.lastPathComponent)' was not queued; wait for the current installs to finish."
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}
