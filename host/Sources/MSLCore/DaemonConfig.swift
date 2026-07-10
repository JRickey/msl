import Foundation

/// Tunables for the resident daemon's shared VM.
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
    public let memoryFloorMiB: UInt64
    public let pollIntervalS: Double
    public let interopEnabled: Bool

    public init(
        home: MSLHome, kernelPath: String, initramfsPath: String, cmdline: String = "console=hvc0",
        cpus: Int? = nil, memoryMiB: UInt64? = nil, shareHomePath: String?,
        bootTimeout: Double = 60, idleTimeoutS: Int = 60, term: String = "xterm-256color",
        memoryFloorMiB: UInt64 = 1024, pollIntervalS: Double = 2,
        interopEnabled: Bool = true, sizing: SharedVMSizing = .current()
    ) {
        precondition(!kernelPath.isEmpty, "kernel path must not be empty")
        precondition(!initramfsPath.isEmpty, "initramfs path must not be empty")
        precondition(memoryFloorMiB >= 256, "memory floor must be at least 256 MiB")
        precondition(pollIntervalS > 0, "poll interval must be positive")
        self.home = home
        self.kernelPath = kernelPath
        self.initramfsPath = initramfsPath
        self.cmdline = cmdline
        self.cpus = cpus ?? sizing.cpuCount
        self.memoryMiB = memoryMiB ?? sizing.memoryMiB
        self.shareHomePath = shareHomePath
        self.bootTimeout = bootTimeout
        self.idleTimeoutS = idleTimeoutS
        self.term = term
        self.memoryFloorMiB = memoryFloorMiB
        self.pollIntervalS = pollIntervalS
        self.interopEnabled = interopEnabled
    }
}
