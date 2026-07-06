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
        submit(.bundle(url))
    }

    func requestCatalogInstall(resolved: CatalogResolved, installedName: String) {
        guard confirmCatalog(resolved: resolved, installedName: installedName) else { return }
        submit(.catalog(resolved, installedName: installedName))
    }

    private func submit(_ request: InstallRequest) {
        switch queue.submit(request) {
        case .started:
            progress.show(message: "Preparing \(request.displayName)…")
            run(request)
        case .queued:
            progress.show(message: "Queued \(request.displayName)…")
        case .dropped:
            warnFull(displayName: request.displayName)
        }
    }

    private func run(_ request: InstallRequest) {
        let home = self.home
        let sink = MenuProgressSink(service: self)
        Task { @MainActor [weak self] in
            let outcome = await InstallRunner.run(home: home, request: request) { event in
                sink.emit(event)
            }
            self?.finish(request: request, outcome: outcome)
        }
    }

    private func finish(request: InstallRequest, outcome: InstallOutcome) {
        Notifier.postInstall(result: outcome, displayName: request.displayName)
        if let next = queue.complete() {
            progress.show(message: "Preparing \(next.displayName)…")
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

    private func confirmCatalog(resolved: CatalogResolved, installedName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install \(resolved.selector) as '\(installedName)'?"
        alert.informativeText = "msl will download and verify the catalog rootfs."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func warnFull(displayName: String) {
        assert(!displayName.isEmpty, "warned install needs a display name")
        let alert = NSAlert()
        alert.messageText = "Too many installs queued"
        alert.informativeText =
            "'\(displayName)' was not queued; wait for the current installs to finish."
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    fileprivate func show(progress event: InstallProgress) {
        let rendered = Self.render(event)
        progress.show(message: rendered.message, fraction: rendered.fraction)
    }

    private static func render(_ event: InstallProgress) -> (message: String, fraction: Double?) {
        switch event {
        case .message(let message):
            return (message, nil)
        case .catalog(let progress):
            return renderCatalog(progress)
        }
    }

    private static func renderCatalog(
        _ event: CatalogDownloadProgress
    ) -> (message: String, fraction: Double?) {
        switch event {
        case .checkingCache:
            return ("Checking cached download…", nil)
        case .cacheHit:
            return ("Using verified cached download", 1)
        case .startingDownload(_, let bytes):
            return ("Starting download (\(humanBytes(bytes)))…", 0)
        case .downloading(let received, let total):
            guard let total, total > 0 else {
                return ("Downloading \(humanBytes(received))…", nil)
            }
            let fraction = min(1, Double(received) / Double(total))
            return (
                "Downloading \(humanBytes(received)) of \(humanBytes(total))…", fraction
            )
        case .verifying(_, let sha256):
            return ("Checking SHA256 \(shortSHA(sha256))…", nil)
        case .ready:
            return ("Download verified", 1)
        }
    }

    private static func shortSHA(_ sha256: String) -> String {
        return String(sha256.prefix(12))
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f%@" : "%.1f%@", value, units[unit])
    }
}

private final class MenuProgressSink: @unchecked Sendable {
    private weak var service: InstallService?

    init(service: InstallService) {
        self.service = service
    }

    func emit(_ event: InstallProgress) {
        Task { @MainActor [weak service] in
            service?.show(progress: event)
        }
    }
}
