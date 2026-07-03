import Foundation

/// Validated boot parameters for a headless VM. `diskPaths` become
/// /dev/vda,/dev/vdb,... in order; `shares` become virtiofs tags.
public struct BootSpec: Sendable {
    public let kernelURL: URL
    public let initramfsURL: URL
    public let commandLine: String
    public let cpuCount: Int
    public let memoryMiB: UInt64
    public let consoleLogPath: String?
    public let execCommand: String?
    public let timeout: Double
    public let diskURLs: [URL]
    public let shares: [ShareSpec]
    public let balloonEnabled: Bool
    /// Attach a VZLinuxRosettaDirectoryshare (tag "rosetta") when set. The caller
    /// must gate this on VMHost.rosettaAvailable(); a false value is the default.
    public let rosettaShare: Bool

    public init(
        kernelPath: String, initramfsPath: String, commandLine: String,
        cpuCount: Int, memoryMiB: UInt64, consoleLogPath: String?,
        execCommand: String?, timeout: Double, diskPaths: [String] = [],
        shares: [ShareSpec] = [], balloonEnabled: Bool = false,
        rosettaShare: Bool = false
    ) throws {
        guard cpuCount >= 1 else { throw MSLError.invalidArgument("cpus must be >= 1") }
        guard memoryMiB >= 1 else { throw MSLError.invalidArgument("memory-mib must be >= 1") }
        guard timeout > 0 else { throw MSLError.invalidArgument("timeout must be > 0") }
        guard !commandLine.isEmpty else { throw MSLError.invalidArgument("cmdline is empty") }
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: kernelPath) else {
            throw MSLError.invalidArgument("kernel not readable: \(kernelPath)")
        }
        guard fileManager.isReadableFile(atPath: initramfsPath) else {
            throw MSLError.invalidArgument("initramfs not readable: \(initramfsPath)")
        }
        self.diskURLs = try Self.validatedDisks(diskPaths, fileManager: fileManager)
        try Self.validateShares(shares, fileManager: fileManager)
        self.kernelURL = URL(fileURLWithPath: kernelPath)
        self.initramfsURL = URL(fileURLWithPath: initramfsPath)
        self.commandLine = commandLine
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.consoleLogPath = consoleLogPath
        self.execCommand = execCommand
        self.timeout = timeout
        self.shares = shares
        self.balloonEnabled = balloonEnabled
        self.rosettaShare = rosettaShare
    }

    private static func validatedDisks(
        _ paths: [String], fileManager: FileManager
    ) throws -> [URL] {
        guard paths.count <= 26 else { throw MSLError.invalidArgument("too many disks (max 26)") }
        var urls: [URL] = []
        for path in paths {  // bounded: at most 26 disks
            guard fileManager.isReadableFile(atPath: path) else {
                throw MSLError.invalidArgument("disk not readable: \(path)")
            }
            urls.append(URL(fileURLWithPath: path))
        }
        return urls
    }

    private static func validateShares(_ shares: [ShareSpec], fileManager: FileManager) throws {
        var seen = Set<String>()
        for share in shares {  // bounded: caller-supplied share list
            guard ShareSpec.isValidTag(share.tag) else {
                throw MSLError.invalidArgument("invalid share tag: \(share.tag)")
            }
            guard seen.insert(share.tag).inserted else {
                throw MSLError.invalidArgument("duplicate share tag: \(share.tag)")
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: share.hostPath, isDirectory: &isDir),
                isDir.boolValue
            else {
                throw MSLError.invalidArgument("share path is not a directory: \(share.hostPath)")
            }
        }
    }
}
