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

    @Flag(help: "Open a shell with GUI display environment for child apps.")
    var gui = false

    func run() throws {
        let home = MSLHome.resolve()
        let term = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"
        let distro: String?
        let extraEnv: [String: String]
        if gui {
            let resolved = try GuiLaunchSupport.resolvedDistroName(home: home, name: name)
            let runtime = try GuiLaunchSupport.startRuntime(home: home, name: resolved)
            distro = resolved
            extraEnv = GuiRuntime.environment(runtimeDir: runtime.runtimeDir)
        } else {
            distro = name
            extraEnv = [:]
        }
        let outcome = try DaemonClient.runSession(
            home: home, name: distro, argv: command, term: term, extraEnv: extraEnv)
        let code = sessionExitCode(outcome)
        guard code == 0 else { throw ExitCode(code) }
    }
}
