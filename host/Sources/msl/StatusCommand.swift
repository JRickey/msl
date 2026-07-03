import ArgumentParser
import Foundation
import MSLCore

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the daemon's VM state and each distro's state and sessions.")

    func run() throws {
        let home = MSLHome.resolve()
        guard DaemonClient.isRunning(home) else {
            print("daemon not running")
            return
        }
        let status = try DaemonClient.status(home)
        let idle = status.idleTimeoutS == 0 ? "never" : "\(status.idleTimeoutS)s"
        print("VM: \(status.vm)    idle-timeout: \(idle)")
        guard !status.distros.isEmpty else {
            print("no distros installed (use 'msl install')")
            return
        }
        print("NAME              STATE         SESSIONS")
        for entry in status.distros {  // bounded: registry list
            print(pad(entry.name, 18) + pad(entry.state, 14) + "\(entry.sessions)")
        }
    }

    private func pad(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }
}
