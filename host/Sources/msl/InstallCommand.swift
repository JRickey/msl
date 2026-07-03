import ArgumentParser
import Foundation
import MSLCore

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a distro from an ext4 image or a root tarball.")

    @Argument(help: "Distro name (^[a-z][a-z0-9-]{0,31}$).")
    var name: String

    @Option(name: .long, help: "Source: an .img ext4 image, or a .tar.xz/.tar.gz root tarball.")
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
        let plan = try InstallPlan.make(
            name: name, fromPath: from, sizeGiB: sizeGib, existingNames: existing)
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
        print("installed \(entry.name)\(marker)")
    }
}
