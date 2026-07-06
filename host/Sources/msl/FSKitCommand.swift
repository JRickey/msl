import ArgumentParser
import Foundation
import MSLCore
import MSLFSWire

struct FSKitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fskit",
        abstract: "Manage the Finder filesystem extension.",
        subcommands: [
            FSKitEnableCommand.self, FSKitStatusCommand.self, FSKitDisableCommand.self,
        ])

    static func restartIfRunning() throws {
        let probe = Subprocess.run("/usr/bin/pgrep", ["-x", "fskitd"])
        guard probe.status == 0 else {
            print("fskitd is not running; macOS will read the setting when it starts")
            return
        }
        print("restarting fskitd (sudo may ask for your password)")
        let result = Subprocess.runInteractive("/usr/bin/sudo", ["/usr/bin/killall", "fskitd"])
        guard result.status == 0 else {
            throw MSLError.io("sudo killall fskitd failed (exit \(result.status))")
        }
    }
}

struct FSKitEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable the msl FSKit module and restart fskitd.")

    @Flag(name: .customLong("no-restart"), help: "Only edit the FSKit settings plist.")
    var noRestart: Bool = false

    func run() throws {
        let changed = try FSKitEnablement.enable()
        print(
            changed
                ? "enabled \(FSProto.appexBundleID)" : "\(FSProto.appexBundleID) already enabled")
        if noRestart {
            print("restart fskitd before mounting so macOS reloads the setting")
            return
        }
        try FSKitCommand.restartIfRunning()
    }
}

struct FSKitStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether the msl FSKit module is enabled.")

    func run() throws {
        let path = FSKitEnablement.plistPath()
        let enabled = try FSKitEnablement.isEnabled()
        print("module: \(FSProto.appexBundleID)")
        print("status: \(enabled ? "enabled" : "disabled")")
        print("plist:  \(path)")
    }
}

struct FSKitDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable the msl FSKit module and restart fskitd.")

    @Flag(name: .customLong("no-restart"), help: "Only edit the FSKit settings plist.")
    var noRestart: Bool = false

    func run() throws {
        let changed = try FSKitEnablement.disable()
        print(
            changed
                ? "disabled \(FSProto.appexBundleID)" : "\(FSProto.appexBundleID) already disabled")
        if noRestart {
            print("restart fskitd before mounting so macOS reloads the setting")
            return
        }
        try FSKitCommand.restartIfRunning()
    }
}
