import ArgumentParser
import Foundation
import MSLCore

struct ShutdownCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shutdown",
        abstract: "Stop every distro, stop the VM, and exit the daemon.")

    func run() throws {
        let home = MSLHome.resolve()
        guard DaemonClient.isRunning(home) else {
            print("daemon not running")
            return
        }
        try DaemonClient.shutdown(home)
        print("daemon shut down")
    }
}
