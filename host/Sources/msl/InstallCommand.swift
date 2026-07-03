import ArgumentParser
import Foundation
import MSLCore

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a distro from an ext4 image, a root tarball, or a .msl bundle.")

    @Argument(
        help:
            "Distro name (^[a-z][a-z0-9-]{0,31}$); optional for a .msl bundle with an embedded name."
    )
    var name: String?

    @Option(
        name: .long,
        help: "Source: an .img ext4 image, a .tar.xz/.tar.gz/.tar root tarball, or a .msl bundle.")
    var from: String

    @Option(name: .long, help: "Image size in GiB for a tarball build (ignored for .img).")
    var sizeGib: Int = 8

    @Option(name: .long, help: "Kernel image for the builder VM (default: MSL home / ./kernel).")
    var kernel: String?

    @Option(name: .long, help: "Builder initramfs (default: MSL home / ./builder-initramfs.cpio).")
    var builderInitramfs: String?

    func run() throws {
        let home = MSLHome.resolve()
        let registry = try Registry.load(from: home.registryURL)
        let existing = registry.distros.map { $0.name }
        let plan = try Self.makePlan(name: name, from: from, sizeGiB: sizeGib, existing: existing)
        let env = ProcessInfo.processInfo.environment
        let options = InstallOptions(
            kernelPath: home.resolvePath(
                flag: kernel, homeCandidate: home.kernelPath, devEnv: env["MSL_KERNEL"],
                devDefault: "kernel"),
            builderInitramfsPath: home.resolvePath(
                flag: builderInitramfs, homeCandidate: home.builderInitramfsPath, devEnv: nil,
                devDefault: "builder-initramfs.cpio"))
        let entry = try InstallDriver(home: home).install(plan: plan, options: options)
        let updated = try Registry.load(from: home.registryURL)
        let marker = updated.defaultDistro == entry.name ? " (default)" : ""
        if let user = entry.defaultUser {
            print("installed \(entry.name)\(marker) (default user: \(user))")
        } else {
            print("installed \(entry.name)\(marker)")
        }
    }

    /// Resolve the install plan: a `.msl` source is sniffed for compression and
    /// its embedded name/default-user; the CLI name wins over the embedded one.
    /// A non-bundle source still requires an explicit name.
    private static func makePlan(
        name: String?, from: String, sizeGiB: Int, existing: [String]
    ) throws -> InstallPlan {
        assert(!from.isEmpty, "--from must not be empty")
        if from.lowercased().hasSuffix(".msl") {
            let info = try BundleReader.read(path: from)
            guard let resolved = name ?? info.meta.name else {
                throw MSLError.invalidArgument(
                    "bundle has no embedded name; pass one: msl install <name> --from \(from)")
            }
            return try InstallPlan.make(
                name: resolved, fromPath: from, sizeGiB: sizeGiB, existingNames: existing,
                bundleCompression: info.compression, defaultUser: info.meta.defaultUser)
        }
        guard let resolved = name else {
            throw MSLError.invalidArgument("name is required for \(from)")
        }
        return try InstallPlan.make(
            name: resolved, fromPath: from, sizeGiB: sizeGiB, existingNames: existing)
    }
}
