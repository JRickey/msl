import ArgumentParser
import Foundation
import MSLCore

struct DesktopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "desktop",
        abstract: "Probe or launch distro desktop sessions.",
        subcommands: [DesktopProbeCommand.self, DesktopLaunchCommand.self])
}

struct DesktopProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "probe")

    @Argument(help: "Installed distro name.")
    var name: String

    func run() throws {
        let result = try DesktopProbe.probe(home: MSLHome.resolve(), name: name)
        if let session = result.session {
            print("available \(session.name) \(session.command)")
        } else {
            print("unavailable")
        }
    }
}

struct DesktopLaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "launch")

    @Argument(help: "Installed distro name.")
    var name: String

    func run() throws {
        try LauncherRuntime.launchDesktop(home: MSLHome.resolve(), name: name)
    }
}
