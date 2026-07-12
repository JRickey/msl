import ArgumentParser
import Foundation
import MSLCore

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the resident msl daemon (foreground run + LaunchAgent).",
        subcommands: [
            DaemonRunCommand.self, DaemonInstallCommand.self, DaemonUninstallCommand.self,
        ])
}

struct DaemonRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon in the foreground (launchd-friendly); serves until stopped.")

    @Option(name: .long, help: "Idle seconds with no sessions before stopping the VM (0 = never).")
    var idleTimeout: Int?

    @Option(name: .long, help: "Virtual CPU count for the shared VM.")
    var cpus: Int?

    @Option(name: .long, help: "Guest memory in MiB for the shared VM.")
    var memoryMib: UInt64?

    @Option(name: .long, help: "Kernel image (default: MSL home, then $MSL_KERNEL or ./kernel).")
    var kernel: String?

    @Option(name: .long, help: "initramfs image (default: MSL home, then $MSL_INITRAMFS).")
    var initramfs: String?

    @Option(name: .long, help: "Kernel command line.")
    var cmdline: String = "console=hvc0"

    @Option(name: .long, help: "Seconds to wait for the guest agent before failing a boot.")
    var timeout: Double = 60

    @Flag(name: .customLong("share-home"), help: "Share $HOME into the VM as the 'mac' tag.")
    var shareHome = false

    @Flag(name: .customLong("no-share-home"), help: "Do not share $HOME into the VM.")
    var noShareHome = false

    @Flag(
        name: .customLong("interop"),
        help: "Serve the linux->mac interop channel (vsock 5010).")
    var interop = false

    @Flag(name: .customLong("no-interop"), help: "Disable the linux->mac interop channel.")
    var noInterop = false

    @Flag(name: .long, help: "Set when auto-spawned by 'msl shell'/'run' (quieter startup).")
    var spawned: Bool = false

    func validate() throws {
        guard !(shareHome && noShareHome) else {
            throw ValidationError("--share-home and --no-share-home are mutually exclusive")
        }
        guard !(interop && noInterop) else {
            throw ValidationError("--interop and --no-interop are mutually exclusive")
        }
        _ = try MSLHostSettings().applyingOverrides(
            cpuCount: cpus, memoryMiB: memoryMib, idleTimeoutS: idleTimeout,
            shareHome: Self.booleanOverride(on: shareHome, off: noShareHome),
            interopEnabled: Self.booleanOverride(on: interop, off: noInterop))
    }

    func run() throws {
        let home = MSLHome.resolve()
        let env = ProcessInfo.processInfo.environment
        let saved = try MSLHostSettingsStore(home: home).load()
        let settings = try saved.applyingOverrides(
            cpuCount: cpus, memoryMiB: memoryMib, idleTimeoutS: idleTimeout,
            shareHome: Self.booleanOverride(on: shareHome, off: noShareHome),
            interopEnabled: Self.booleanOverride(on: interop, off: noInterop))
        let config = DaemonConfig(
            home: home,
            kernelPath: home.resolvePath(
                flag: kernel, homeCandidate: home.kernelPath, devEnv: env["MSL_KERNEL"],
                devDefault: "kernel"),
            initramfsPath: home.resolvePath(
                flag: initramfs, homeCandidate: home.initramfsPath, devEnv: env["MSL_INITRAMFS"],
                devDefault: "initramfs.cpio"),
            cmdline: cmdline, cpus: settings.cpuCount, memoryMiB: settings.memoryMiB,
            shareHomePath: settings.shareHome ? NSHomeDirectory() : nil, bootTimeout: timeout,
            idleTimeoutS: settings.idleTimeoutS, term: env["TERM"] ?? "xterm-256color",
            interopEnabled: settings.interopEnabled)
        DaemonRuntime.run(config: config, spawned: spawned)
    }

    private static func booleanOverride(on: Bool, off: Bool) -> Bool? {
        assert(!(on && off), "contradictory flags are rejected during validation")
        if on { return true }
        if off { return false }
        return nil
    }
}

struct DaemonInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the LaunchAgent so the daemon starts at login and stays up.")

    func run() throws {
        let exe = SpawnDaemon.selfExecutablePath()
        try LaunchAgent.install(executablePath: exe)
        print("installed LaunchAgent \(LaunchAgent.label) -> \(LaunchAgent.plistPath())")
    }
}

struct DaemonUninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the LaunchAgent (does not stop a running daemon).")

    func run() throws {
        try LaunchAgent.uninstall()
        print("removed LaunchAgent \(LaunchAgent.label)")
    }
}
