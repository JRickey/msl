import Foundation
import MSLCore

/// Host-side install planning shared with the CLI's `install` command: resolve
/// the plan from a `.msl` bundle (embedded name/compression) and the builder
/// options from the MSL home, without booting anything. The driver call that
/// consumes this lives in the app layer; this stays VM-free so it is testable.
public enum MenuBarInstall {
    /// A ready-to-run install: the validated plan plus builder tunables.
    public struct Prepared: Sendable {
        public let plan: InstallPlan
        public let options: InstallOptions

        public init(plan: InstallPlan, options: InstallOptions) {
            self.plan = plan
            self.options = options
        }
    }

    public static let defaultSizeGiB = 8

    /// Build the plan+options for a `.msl` file the way `msl install` does:
    /// sniff the bundle, take the embedded name (double-click has no argument to
    /// override it), and resolve the kernel/builder paths from the MSL home.
    public static func prepare(
        bundlePath: String, home: MSLHome,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Prepared {
        precondition(!bundlePath.isEmpty, "bundle path must not be empty")
        guard bundlePath.lowercased().hasSuffix(".msl") else {
            throw MSLError.invalidArgument("not a .msl bundle: \(bundlePath)")
        }
        let registry = try Registry.load(from: home.registryURL)
        let existing = registry.distros.map { $0.name }
        let info = try BundleReader.read(path: bundlePath)
        guard let name = info.meta.name else {
            throw MSLError.invalidArgument(
                "bundle has no embedded name; install it from the CLI with an explicit name")
        }
        assert(Registry.isValidName(name), "BundleReader validates the embedded name")
        let plan = try InstallPlan.make(
            name: name, fromPath: bundlePath, sizeGiB: defaultSizeGiB, existingNames: existing,
            bundleCompression: info.compression, defaultUser: info.meta.defaultUser)
        return Prepared(plan: plan, options: resolveOptions(home: home, env: env))
    }

    public static func prepare(
        catalog resolved: CatalogResolved, installedName: String, sourceURL: URL, home: MSLHome,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Prepared {
        precondition(!sourceURL.path.isEmpty, "catalog source path must not be empty")
        let registry = try Registry.load(from: home.registryURL)
        let source = InstallSource.tarball(sourceURL, resolved.artifact.compression)
        let plan = try InstallPlan.make(
            name: installedName, source: source, sizeGiB: resolved.version.imageSizeGiB,
            existingNames: registry.distros.map { $0.name },
            defaultUser: resolved.version.defaultUser,
            catalogSelector: resolved.selector)
        return Prepared(plan: plan, options: resolveOptions(home: home, env: env))
    }

    private static func resolveOptions(home: MSLHome, env: [String: String]) -> InstallOptions {
        assert(!home.kernelPath.isEmpty, "home resolves a kernel path")
        return InstallOptions(
            kernelPath: home.resolvePath(
                flag: nil, homeCandidate: home.kernelPath, devEnv: env["MSL_KERNEL"],
                devDefault: "kernel"),
            builderInitramfsPath: home.resolvePath(
                flag: nil, homeCandidate: home.builderInitramfsPath, devEnv: nil,
                devDefault: "builder-initramfs.cpio"))
    }
}
