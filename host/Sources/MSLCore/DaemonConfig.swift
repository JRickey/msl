import Foundation

/// Tunables for the resident daemon's shared VM. The daemon boots lazily from
/// the registry, so most of these mirror `msl up`'s defaults.
public struct DaemonConfig: Sendable {
    public let home: MSLHome
    public let kernelPath: String
    public let initramfsPath: String
    public let cmdline: String
    public let cpus: Int
    public let memoryMiB: UInt64
    public let shareHomePath: String?
    public let bootTimeout: Double
    public let idleTimeoutS: Int
    public let term: String

    public init(
        home: MSLHome, kernelPath: String, initramfsPath: String, cmdline: String = "console=hvc0",
        cpus: Int = 4, memoryMiB: UInt64 = 4096, shareHomePath: String?, bootTimeout: Double = 60,
        idleTimeoutS: Int = 60, term: String = "xterm-256color"
    ) {
        precondition(!kernelPath.isEmpty, "kernel path must not be empty")
        precondition(!initramfsPath.isEmpty, "initramfs path must not be empty")
        self.home = home
        self.kernelPath = kernelPath
        self.initramfsPath = initramfsPath
        self.cmdline = cmdline
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.shareHomePath = shareHomePath
        self.bootTimeout = bootTimeout
        self.idleTimeoutS = idleTimeoutS
        self.term = term
    }
}
