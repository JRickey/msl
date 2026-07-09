import ArgumentParser
import Darwin
import Foundation
import MSLCore

struct GuiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gui",
        abstract: "Probe, enable, and launch Linux GUI apps as native windows.",
        subcommands: [
            GuiProbeCommand.self, GuiEnableCommand.self, GuiStatusCommand.self,
            GuiLaunchCommand.self, GuiStopCommand.self,
        ])
}

struct GuiProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe", abstract: "Report GUI runtime capabilities for a distro.")

    @Argument(help: "Distro to probe.")
    var name: String

    func run() throws {
        let home = MSLHome.resolve()
        let probe = try DaemonClient.guiProbe(home: home, name: name)
        GuiLaunchSupport.printProbe(probe)
    }
}

struct GuiEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Show or install GUI runtime packages for a distro.")

    @Argument(help: "Distro to prepare.")
    var name: String

    @Flag(help: "Install packages through the distro package manager.")
    var installPackages = false

    func run() throws {
        guard installPackages else {
            print(GuiRuntime.enablePlan())
            return
        }
        try GuiLaunchSupport.printCapture(name: name, script: GuiRuntime.enableInstallScript())
    }
}

struct GuiStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show GUI runtime state for a distro.")

    @Argument(help: "Distro to inspect.")
    var name: String?

    func run() throws {
        let home = MSLHome.resolve()
        let distro = try GuiLaunchSupport.resolvedDistroName(home: home, name: name)
        let status = try DaemonClient.guiStatus(home: home, name: distro)
        GuiLaunchSupport.printRuntime(status)
    }
}

struct GuiStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop the GUI compositor for a distro.")

    @Argument(help: "Distro whose GUI runtime should stop.")
    var name: String

    func run() throws {
        let home = MSLHome.resolve()
        let status = try DaemonClient.guiStop(home: home, name: name)
        GuiLaunchSupport.printRuntime(status)
    }
}

struct GuiLaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch", abstract: "Launch one Linux GUI command and present its windows.")

    @Argument(help: "Distro to launch in.")
    var name: String

    @Argument(parsing: .postTerminator, help: "Command after -- (required).")
    var command: [String] = []

    @Option(name: .long, help: "CSV path for the latency ledger.")
    var csv: String = "./gui.csv"

    func run() throws {
        try GuiLaunchSupport.launch(name: name, command: command, csv: csv)
    }
}

enum GuiLaunchSupport {
    static func launch(name: String?, command: [String], csv: String = "./gui.csv") throws {
        guard !command.isEmpty else {
            throw ValidationError("usage: msl gui launch <distro> -- <command> [args...]")
        }
        let home = MSLHome.resolve()
        let distro = try resolvedDistroName(home: home, name: name)
        _ = try startRuntime(home: home, name: distro)
        try launchApp(home: home, name: distro, command: command)
        let fd = try openSurfacePlane(home: home, name: distro)
        let channel = try GuiChannel(fd: fd)
        MainActor.assumeIsolated {
            GuiPresenter(channel: channel, distro: distro, csvPath: csv).run()
        }
    }

    static func resolvedDistroName(home: MSLHome, name: String?) throws -> String {
        return try Registry.load(from: home.registryURL).resolveDefault(requested: name).name
    }

    static func printProbe(_ probe: GuiProbeData) {
        printRuntime(probe.runtime)
        for capability in probe.capabilities {
            let state = capability.present ? "present" : "missing"
            print("\(capability.name)=\(state)")
        }
    }

    static func printRuntime(_ runtime: GuiRuntimeData) {
        print("state=\(runtime.state)")
        print("runtime_dir=\(runtime.runtimeDir)")
        print("wayland=\(runtime.waylandDisplay)")
        print("socket=\(runtime.socketPresent ? "present" : "missing")")
        if let pid = runtime.pid {
            print("pid=\(pid)")
        }
        if !runtime.logTail.isEmpty {
            print(runtime.logTail)
        }
    }

    static func printCapture(name: String, script: String) throws {
        let home = MSLHome.resolve()
        let data = try capture(home: home, name: name, script: script)
        print(data.stdout, terminator: data.stdout.hasSuffix("\n") ? "" : "\n")
        if !data.stderr.isEmpty {
            FileHandle.standardError.write(Data(data.stderr.utf8))
        }
        guard data.exitCode == 0 else { throw ExitCode(data.exitCode) }
    }

    static func startRuntime(home: MSLHome, name: String) throws -> GuiRuntimeData {
        return try DaemonClient.guiStart(home: home, name: name)
    }

    private static func launchApp(home: MSLHome, name: String, command: [String]) throws {
        let data = try DaemonClient.guiLaunch(
            home: home,
            req: GuiLaunchReq(distro: name, argv: launchArgv(command: command), cwd: "/"))
        guard data.exitCode == 0 else {
            writeError(data)
            throw ExitCode(data.exitCode)
        }
    }

    private static func launchArgv(command: [String]) -> [String] {
        precondition(!command.isEmpty, "GUI launch command must not be empty")
        let script =
            "uid=\"$(id -u)\"; export XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/tmp/msl-gui-$uid}\"; "
            + "nohup \"$@\" > /dev/null 2>&1 < /dev/null & echo launched"
        return ["/bin/sh", "-lc", script, "msl-gui-launch"] + command
    }

    private static func capture(home: MSLHome, name: String, script: String) throws -> ExecData {
        return try DaemonClient.capture(
            home: home, name: name, argv: ["/bin/sh", "-lc", script], term: "dumb")
    }

    private static func openSurfacePlane(home: MSLHome, name: String) throws -> Int32 {
        try DaemonClient.ensureRunning(home)
        let control = try DaemonClient.connect(home)
        defer { control.close() }
        do {
            return try control.guiConnectRaw(name: name)
        } catch {
            let message = (error as? MSLError)?.description ?? error.localizedDescription
            FileHandle.standardError.write(
                Data("msl gui: cannot reach compositor: \(message)\n".utf8))
            throw ExitCode(1)
        }
    }

    private static func writeError(_ data: ExecData) {
        if !data.stdout.isEmpty { FileHandle.standardError.write(Data(data.stdout.utf8)) }
        if !data.stderr.isEmpty { FileHandle.standardError.write(Data(data.stderr.utf8)) }
    }
}
