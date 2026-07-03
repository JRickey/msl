import Foundation

/// The MSL state directory (`$MSL_HOME`, default `~/.msl`): kernel, initramfs
/// images, the per-distro image store, and the registry. Path resolution keeps
/// the precedence flag > MSL home file > repo-relative dev fallback so the same
/// binary works both from an installed home and from a checkout.
public struct MSLHome: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Resolve the home from the environment: `MSL_HOME` if set and non-empty,
    /// otherwise `~/.msl`.
    public static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> MSLHome {
        if let override = env["MSL_HOME"], !override.isEmpty {
            return MSLHome(root: URL(fileURLWithPath: override))
        }
        let base = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".msl")
        return MSLHome(root: base)
    }

    public var kernelPath: String { root.appendingPathComponent("kernel").path }
    public var initramfsPath: String { root.appendingPathComponent("initramfs.cpio").path }
    public var builderInitramfsPath: String {
        root.appendingPathComponent("builder-initramfs.cpio").path
    }
    public var distrosDirectory: URL { root.appendingPathComponent("distros") }
    public var logsDirectory: URL { root.appendingPathComponent("logs") }
    public var registryURL: URL { root.appendingPathComponent("registry.json") }

    /// Filesystem path of a distro's backing image (`distros/<name>.img`).
    public func imageURL(name: String) -> URL {
        precondition(!name.isEmpty, "distro name must not be empty")
        return distrosDirectory.appendingPathComponent(name + ".img")
    }

    /// Create the home, `distros/`, and `logs/` directories if absent.
    public func ensureDirectories() throws {
        let fileManager = FileManager.default
        for dir in [root, distrosDirectory, logsDirectory] {  // bounded: three dirs
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Resolve a kernel/initramfs path with the standard precedence. `flag` wins;
    /// then the MSL home candidate if it is readable; then the dev fallback.
    public func resolvePath(
        flag: String?, homeCandidate: String, devEnv: String?, devDefault: String
    ) -> String {
        precondition(!devDefault.isEmpty, "dev default must not be empty")
        if let flag, !flag.isEmpty { return flag }
        if FileManager.default.isReadableFile(atPath: homeCandidate) { return homeCandidate }
        if let devEnv, !devEnv.isEmpty { return devEnv }
        return devDefault
    }
}
