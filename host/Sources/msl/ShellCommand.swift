import ArgumentParser
import Foundation
import MSLCore

struct ShellCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Open a shell in a distro via the resident daemon (auto-starting it).")

    @Argument(help: "Distro to enter (default: the registry default).")
    var name: String?

    @Argument(parsing: .postTerminator, help: "Command after --; default is a login shell.")
    var command: [String] = []

    func run() throws {
        let home = MSLHome.resolve()
        let term = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"
        let outcome = try DaemonClient.runSession(
            home: home, name: name, argv: command, term: term)
        let code = sessionExitCode(outcome)
        guard code == 0 else { throw ExitCode(code) }
    }
}
