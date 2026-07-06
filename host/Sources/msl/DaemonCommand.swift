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
    var idleTimeout: Int = 60

    @Option(name: .long, help: "Virtual CPU count for the shared VM.")
    var cpus: Int = 4

    @Option(name: .long, help: "Guest memory in MiB for the shared VM.")
    var memoryMib: UInt64 = 4096

    @Option(name: .long, help: "Kernel image (default: MSL home, then $MSL_KERNEL or ./kernel).")
    var kernel: String?

    @Option(name: .long, help: "initramfs image (default: MSL home, then $MSL_INITRAMFS).")
    var initramfs: String?

    @Option(name: .long, help: "Kernel command line.")
    var cmdline: String = "console=hvc0"

    @Option(name: .long, help: "Seconds to wait for the guest agent before failing a boot.")
    var timeout: Double = 60

    @Flag(name: .long, inversion: .prefixedNo, help: "Share $HOME into the VM as the 'mac' tag.")
    var shareHome: Bool = true

    @Flag(
        name: .long, inversion: .prefixedNo,
        help: "Serve the linux->mac interop channel (vsock 5010).")
    var interop: Bool = true

    @Flag(name: .long, help: "Set when auto-spawned by 'msl shell'/'run' (quieter startup).")
    var spawned: Bool = false

    func run() throws {
        guard idleTimeout >= 0 else {
            throw ValidationError("--idle-timeout must be >= 0 (0 = never)")
        }
        let home = MSLHome.resolve()
        let env = ProcessInfo.processInfo.environment
        let config = DaemonConfig(
            home: home,
            kernelPath: home.resolvePath(
                flag: kernel, homeCandidate: home.kernelPath, devEnv: env["MSL_KERNEL"],
                devDefault: "kernel"),
            initramfsPath: home.resolvePath(
                flag: initramfs, homeCandidate: home.initramfsPath, devEnv: env["MSL_INITRAMFS"],
                devDefault: "initramfs.cpio"),
            cmdline: cmdline, cpus: cpus, memoryMiB: memoryMib,
            shareHomePath: shareHome ? NSHomeDirectory() : nil, bootTimeout: timeout,
            idleTimeoutS: idleTimeout, term: env["TERM"] ?? "xterm-256color",
            interopEnabled: interop)
        DaemonRuntime.run(config: config, spawned: spawned)
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
