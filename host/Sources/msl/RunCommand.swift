import ArgumentParser
import Foundation
import MSLCore

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run one command in a distro via the daemon; exit code is faithful.")

    @Argument(help: "Distro to run in (default: the registry default).")
    var name: String?

    @Argument(parsing: .postTerminator, help: "Command after -- (required).")
    var command: [String] = []

    func run() throws {
        guard !command.isEmpty else {
            throw ValidationError("usage: msl run [name] -- <command> [args...]")
        }
        let home = MSLHome.resolve()
        let term = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"
        let outcome = try DaemonClient.runSession(
            home: home, name: name, argv: command, term: term)
        let code = sessionExitCode(outcome)
        guard code == 0 else { throw ExitCode(code) }
    }
}
