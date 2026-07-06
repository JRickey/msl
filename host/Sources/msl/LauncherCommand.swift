import ArgumentParser
import Foundation
import MSLCore

struct LauncherCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launcher",
        abstract: "Manage macOS app launchers for installed distros.",
        subcommands: [
            LauncherListCommand.self, LauncherCreateCommand.self, LauncherRemoveCommand.self,
            LauncherRefreshCommand.self, LauncherRevealCommand.self, LauncherOpenCommand.self,
            LauncherRunBundleCommand.self,
        ])
}

struct LauncherListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")

    func run() throws {
        let home = MSLHome.resolve()
        let registry = try Registry.load(from: home.registryURL)
        let rows = try LauncherStore(home: home).rows(registry: registry)
        print("DISTRO             MODE       STATE      PATH")
        for row in rows {  // bounded: registry list
            let mode = row.launchMode?.rawValue ?? "-"
            let state = row.exists ? "present" : "missing"
            print(pad(row.distro, 19) + pad(mode, 11) + pad(state, 11) + row.path)
        }
    }

    private func pad(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }
}

struct LauncherCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")

    @Argument(help: "Installed distro name.")
    var name: String

    @Option(name: .long, help: "Launch mode: shell, auto, or desktop.")
    var mode: LauncherMode = .shell

    @Flag(name: .long, help: "Replace an existing msl-owned launcher.")
    var replace = false

    func run() throws {
        let url = try LauncherStore(home: MSLHome.resolve()).create(
            name: name, mode: mode, replace: replace)
        print("created \(url.path)")
    }
}

struct LauncherRefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "refresh")

    @Argument(help: "Installed distro name.")
    var name: String

    @Option(name: .long, help: "Launch mode: shell, auto, or desktop.")
    var mode: LauncherMode = .shell

    func run() throws {
        let url = try LauncherStore(home: MSLHome.resolve()).create(
            name: name, mode: mode, replace: true)
        print("refreshed \(url.path)")
    }
}

struct LauncherRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove")

    @Argument(help: "Installed distro name.")
    var name: String

    func run() throws {
        try LauncherStore(home: MSLHome.resolve()).remove(name: name)
        print("removed launcher for \(name)")
    }
}

struct LauncherRevealCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reveal")

    @Argument(help: "Installed distro name.")
    var name: String

    func run() throws {
        try LauncherStore(home: MSLHome.resolve()).reveal(name: name)
    }
}

struct LauncherOpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open")

    @Argument(help: "Installed distro name.")
    var name: String

    func run() throws {
        try LauncherStore(home: MSLHome.resolve()).open(name: name)
    }
}

struct LauncherRunBundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run-bundle", shouldDisplay: false)

    @Argument(help: "Launcher app bundle path.")
    var path: String

    func run() throws {
        try LauncherRuntime.runBundle(URL(fileURLWithPath: path), home: MSLHome.resolve())
    }
}

extension LauncherMode: ExpressibleByArgument {}
