import ArgumentParser
import Foundation
import MSLCore

struct BootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a headless Linux VM and drive the guest agent over vsock.")

    @Argument(help: ArgumentHelp(visibility: .hidden))
    var target: String?

    @Option(name: .long, help: "Path to the Linux kernel image.")
    var kernel: String?

    @Option(name: .long, help: "Path to the initramfs cpio image.")
    var initramfs: String?

    @Option(name: .long, help: "Kernel command line.")
    var cmdline: String = "console=hvc0"

    @Option(name: .long, help: "Virtual CPU count.")
    var cpus: Int = 2

    @Option(name: .long, help: "Guest memory in MiB.")
    var memoryMib: UInt64 = 2048

    @Option(name: .long, help: "Console log path (default: temp file, path printed).")
    var consoleLog: String?

    @Option(name: .long, help: "Shell command to run in the guest, then exit.")
    var exec: String?

    @Option(name: .long, help: "Seconds to wait for the guest agent before failing.")
    var timeout: Double = 60

    @Option(name: .long, help: "Disk image, repeatable; ordered /dev/vda, /dev/vdb, ...")
    var disk: [String] = []

    @Option(name: .long, help: "virtiofs share tag=hostpath[:ro], repeatable.")
    var share: [String] = []

    func run() throws {
        try rejectRegisteredDistroBoot()
        let kernelPath = try requirePath(kernel, flag: "--kernel")
        let initramfsPath = try requirePath(initramfs, flag: "--initramfs")
        let shares = try share.map { try ShareSpec.parse($0) }
        let spec = try BootSpec(
            kernelPath: kernelPath,
            initramfsPath: initramfsPath,
            commandLine: cmdline,
            cpuCount: cpus,
            memoryMiB: memoryMib,
            consoleLogPath: consoleLog,
            execCommand: exec,
            timeout: timeout,
            diskPaths: disk,
            shares: shares)
        let host = VMHost(spec: spec)
        let driver = Driver(host: host, spec: spec)
        driver.launch()
        dispatchMain()
    }

    private func rejectRegisteredDistroBoot() throws {
        guard let target, !target.isEmpty else { return }
        throw ValidationError(
            "'msl boot \(target)' is the low-level VM boot command, not the "
                + "registered-distro flow. Use 'msl shell \(target)', "
                + "'msl run \(target) -- <command>', or 'msl up --distro \(target)'.")
    }

    private func requirePath(_ value: String?, flag: String) throws -> String {
        assert(!flag.isEmpty, "flag name must not be empty")
        guard let value, !value.isEmpty else {
            throw ValidationError(
                "\(flag) is required for low-level VM boot; installed distros use "
                    + "'msl shell <name>' or 'msl run <name> -- <command>'.")
        }
        return value
    }
}
