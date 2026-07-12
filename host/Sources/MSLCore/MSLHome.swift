import Foundation

/// The MSL state directory (`$MSL_HOME`, default `~/.msl`): kernel, initramfs
/// images, the per-distro image store, and the registry. Path resolution keeps
/// one binary usable from a checkout, an installed home, or the app bundle.
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
    public var cacheDirectory: URL { root.appendingPathComponent("cache") }
    public var catalogCacheDirectory: URL {
        cacheDirectory.appendingPathComponent("catalog")
    }
    public var catalogIconCacheDirectory: URL {
        cacheDirectory.appendingPathComponent("catalog-icons")
    }
    public var logsDirectory: URL { root.appendingPathComponent("logs") }
    public var authDirectory: URL { root.appendingPathComponent("auth") }
    public var authPolicyURL: URL { authDirectory.appendingPathComponent("policy.json") }
    public var secretsMetadataURL: URL { authDirectory.appendingPathComponent("secrets.json") }
    public var hostSettingsURL: URL { root.appendingPathComponent("config.json") }
    public var registryURL: URL { root.appendingPathComponent("registry.json") }
    public var launchersURL: URL { root.appendingPathComponent("launchers.json") }

    /// Filesystem path of a distro's backing image (`distros/<name>.img`).
    public func imageURL(name: String) -> URL {
        precondition(!name.isEmpty, "distro name must not be empty")
        return distrosDirectory.appendingPathComponent(name + ".img")
    }

    /// Create the home, `distros/`, and `logs/` directories if absent.
    public func ensureDirectories() throws {
        let fileManager = FileManager.default
        for dir in [root, distrosDirectory, logsDirectory, authDirectory] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Resolve a kernel/initramfs path with release and dev fallbacks.
    public func resolvePath(
        flag: String?, homeCandidate: String, devEnv: String?, devDefault: String
    ) -> String {
        precondition(!devDefault.isEmpty, "dev default must not be empty")
        if let flag, !flag.isEmpty { return flag }
        if FileManager.default.isReadableFile(atPath: homeCandidate) { return homeCandidate }
        if let devEnv, !devEnv.isEmpty { return devEnv }
        let resource = URL(fileURLWithPath: devDefault).lastPathComponent
        if let bundled = Self.bundledResourcePath(named: resource) { return bundled }
        return devDefault
    }

    public static func bundledResourcePath(
        named name: String,
        executablePath: String? = Bundle.main.executablePath,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> String? {
        precondition(!name.isEmpty, "resource name must not be empty")
        if let bundleResourceURL {
            let candidate = bundleResourceURL.appendingPathComponent(name).path
            if fileManager.isReadableFile(atPath: candidate) { return candidate }
        }
        guard let executablePath, !executablePath.isEmpty else { return nil }
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        let appPath = NSString.path(withComponents: Array(components[0...appIndex]))
        let candidate = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(name).path
        return fileManager.isReadableFile(atPath: candidate) ? candidate : nil
    }
}
