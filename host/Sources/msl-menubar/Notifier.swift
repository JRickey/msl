import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for install and daemon
/// completion notices. Authorization and delivery failures are swallowed: a
/// missing notification must never break the install flow.
enum Notifier {
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postInstall(result: InstallOutcome, url: URL) {
        switch result {
        case .installed(let name):
            post(title: "Installed \(name)", body: "\(url.lastPathComponent) is ready.")
        case .failed(let message):
            post(title: "Install failed", body: "\(url.lastPathComponent): \(message)")
        }
    }

    static func postDaemon(title: String, message: String) {
        assert(!title.isEmpty, "daemon notice needs a title")
        post(title: title, body: message)
    }

    private static func post(title: String, body: String) {
        assert(!title.isEmpty, "notification needs a title")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
