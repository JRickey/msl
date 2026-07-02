import ArgumentParser
import Foundation
import MSLCore

struct UpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Boot a rootfs, bring the distro up, and (with --shell) attach a shell.")

    @Option(name: .long, help: "Root filesystem image (becomes /dev/vda).")
    var rootfs: String

    @Option(name: .long, help: "Kernel image (default: $MSL_KERNEL or ./kernel).")
    var kernel: String?

    @Option(name: .long, help: "initramfs image (default: $MSL_INITRAMFS or ./initramfs.cpio.gz).")
    var initramfs: String?

    @Option(name: .long, help: "Kernel command line.")
    var cmdline: String = "console=hvc0"

    @Option(name: .long, help: "Guest hostname.")
    var hostname: String = "ubuntu"

    @Flag(name: .long, help: "Share $HOME into the guest as the 'mac' virtiofs tag.")
    var shareHome: Bool = false

    @Flag(name: .long, help: "Open an interactive shell, then shut the VM down on exit.")
    var shell: Bool = false

    @Option(name: .long, help: "Virtual CPU count.")
    var cpus: Int = 2

    @Option(name: .long, help: "Guest memory in MiB.")
    var memoryMib: UInt64 = 2048

    @Option(name: .long, help: "Console log path (default: temp file, path printed).")
    var consoleLog: String?

    @Option(name: .long, help: "Seconds to wait for the guest agent before failing.")
    var timeout: Double = 60

    @Argument(parsing: .postTerminator, help: "Shell argv after --; default /bin/bash -l.")
    var command: [String] = []

    // The daemon must outlive run(): in resident (non-shell) mode drive()
    // returns after installing the SIGINT source, so a stack-local driver would
    // be released by ARC and its DispatchSource cancelled — leaving SIGINT set
    // to SIG_IGN and Ctrl-C dead. A static holder pins it for process lifetime.
    nonisolated(unsafe) private static var retainedDriver: UpDriver?

    func run() throws {
        let home = NSHomeDirectory()
        let shares = shareHome ? [ShareSpec(tag: "mac", hostPath: home, readOnly: false)] : []
        let spec = try BootSpec(
            kernelPath: resolvedKernel(),
            initramfsPath: resolvedInitramfs(),
            commandLine: cmdline,
            cpuCount: cpus,
            memoryMiB: memoryMib,
            consoleLogPath: consoleLog,
            execCommand: nil,
            timeout: timeout,
            diskPaths: [rootfs],
            shares: shares)
        let config = UpConfig(
            hostname: hostname,
            shell: shell,
            shellArgv: command.isEmpty ? ["/bin/bash", "-l"] : command,
            home: home,
            hostCwd: FileManager.default.currentDirectoryPath,
            term: ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color")
        let host = VMHost(spec: spec)
        let driver = UpDriver(host: host, spec: spec, config: config)
        Self.retainedDriver = driver
        driver.launch()
        dispatchMain()
    }

    private func resolvedKernel() -> String {
        if let kernel { return kernel }
        return ProcessInfo.processInfo.environment["MSL_KERNEL"] ?? "kernel"
    }

    private func resolvedInitramfs() -> String {
        if let initramfs { return initramfs }
        return ProcessInfo.processInfo.environment["MSL_INITRAMFS"] ?? "initramfs.cpio.gz"
    }
}
