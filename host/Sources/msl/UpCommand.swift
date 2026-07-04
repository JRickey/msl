import ArgumentParser
import Foundation
import MSLCore

struct UpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Boot a registered distro (or a one-off rootfs) and attach a shell.")

    @Option(name: .long, help: "Registered distro to boot (default: the registry default).")
    var distro: String?

    @Option(name: .long, help: "Boot an unregistered rootfs image directly (anonymous one-off).")
    var rootfs: String?

    @Option(name: .long, help: "Kernel image (default: MSL home, then $MSL_KERNEL or ./kernel).")
    var kernel: String?

    @Option(name: .long, help: "initramfs image (default: MSL home, then $MSL_INITRAMFS).")
    var initramfs: String?

    @Option(name: .long, help: "Kernel command line.")
    var cmdline: String = "console=hvc0"

    @Option(name: .long, help: "Override the guest hostname (default: the distro's hostname).")
    var hostname: String?

    @Flag(name: .long, help: "Share $HOME into the guest as the 'mac' virtiofs tag.")
    var shareHome: Bool = false

    @Flag(name: .long, help: "Open an interactive shell, then shut the VM down on exit.")
    var shell: Bool = false

    @Flag(
        name: .long, inversion: .prefixedNo,
        help: "Attach Rosetta x86-64 translation (default: the registered distro's opt-in).")
    var rosetta: Bool?

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
        let home = MSLHome.resolve()
        let target = try resolveTarget(home: home)
        let userHome = NSHomeDirectory()
        let shares = shareHome ? [ShareSpec(tag: "mac", hostPath: userHome, readOnly: false)] : []
        let useRosetta = resolveRosetta(optIn: target.rosetta)
        let spec = try BootSpec(
            kernelPath: resolvedKernel(home), initramfsPath: resolvedInitramfs(home),
            commandLine: cmdline, cpuCount: cpus, memoryMiB: memoryMib,
            consoleLogPath: consoleLog, execCommand: nil, timeout: timeout,
            diskPaths: [target.imagePath], shares: shares, rosettaShare: useRosetta)
        let config = UpConfig(
            distroName: target.distroName, hostname: target.hostname,
            shell: shell || !command.isEmpty,
            shellArgv: command.isEmpty ? ["/bin/bash", "-l"] : command, home: userHome,
            hostCwd: FileManager.default.currentDirectoryPath,
            term: ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color",
            rosetta: useRosetta)
        let driver = UpDriver(host: VMHost(spec: spec), spec: spec, config: config)
        Self.retainedDriver = driver
        driver.launch()
        dispatchMain()
    }

    private struct Target {
        let imagePath: String
        let distroName: String
        let hostname: String
        /// The registered distro's Rosetta opt-in; false for anonymous --rootfs.
        let rosetta: Bool
    }

    /// Resolve the disk, distro name, and hostname from `--rootfs` (anonymous
    /// one-off) or the registry (`--distro`, else the registry default).
    private func resolveTarget(home: MSLHome) throws -> Target {
        if let rootfs {
            let name = anonymousName()
            guard Registry.isValidName(name) else {
                throw MSLError.invalidArgument("invalid distro name: \(name)")
            }
            return Target(
                imagePath: rootfs, distroName: name, hostname: hostname ?? name, rosetta: false)
        }
        let registry = try Registry.load(from: home.registryURL)
        let entry = try registry.resolveDefault(requested: distro)
        let image = home.imageURL(name: entry.name).path
        guard FileManager.default.isReadableFile(atPath: image) else {
            throw MSLError.io("distro image missing: \(image)")
        }
        return Target(
            imagePath: image, distroName: entry.name, hostname: hostname ?? entry.hostname,
            rosetta: entry.rosetta ?? false)
    }

    /// Fold the `--rosetta`/`--no-rosetta` flag (nil ⇒ follow the distro opt-in)
    /// with host availability. A request without Rosetta installed warns and
    /// boots without it, mirroring the daemon's resolveRosettaShare gate.
    private func resolveRosetta(optIn: Bool) -> Bool {
        let wanted = rosetta ?? optIn
        guard wanted else { return false }
        guard VMHost.rosettaAvailable() else {
            warn(
                "rosetta requested but not installed; run "
                    + "'softwareupdate --install-rosetta' — booting without it")
            return false
        }
        return true
    }

    private func warn(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("msl: \(message)\n".utf8))
    }

    /// Distro name for an anonymous `--rootfs` boot: `--distro` if given, else
    /// the hostname when it is a valid distro name, else a neutral fallback.
    private func anonymousName() -> String {
        if let distro { return distro }
        if let hostname, Registry.isValidName(hostname) { return hostname }
        return "linux"
    }

    private func resolvedKernel(_ home: MSLHome) -> String {
        let env = ProcessInfo.processInfo.environment
        return home.resolvePath(
            flag: kernel, homeCandidate: home.kernelPath, devEnv: env["MSL_KERNEL"],
            devDefault: "kernel")
    }

    private func resolvedInitramfs(_ home: MSLHome) -> String {
        let env = ProcessInfo.processInfo.environment
        return home.resolvePath(
            flag: initramfs, homeCandidate: home.initramfsPath, devEnv: env["MSL_INITRAMFS"],
            devDefault: "initramfs.cpio.gz")
    }
}
