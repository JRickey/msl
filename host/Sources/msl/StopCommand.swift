import ArgumentParser
import Foundation
import MSLCore

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a distro gracefully (or the whole VM with --all).")

    @Argument(help: "Distro to stop (default: the registry default).")
    var name: String?

    @Flag(name: .long, help: "Stop every distro and shut the VM down (daemon stays).")
    var all: Bool = false

    func run() throws {
        let home = MSLHome.resolve()
        guard DaemonClient.isRunning(home) else {
            print("daemon not running")
            return
        }
        try DaemonClient.down(home, name: all ? nil : name, all: all)
        print(all ? "VM stopped" : "stopped \(name ?? "default distro")")
    }
}
