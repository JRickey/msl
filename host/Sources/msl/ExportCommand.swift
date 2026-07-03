import ArgumentParser
import Foundation
import MSLCore

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a distro's filesystem to a .tar archive.")

    @Argument(help: "Distro name to export.")
    var name: String

    @Option(name: .long, help: "Output tarball path (must end in .tar; default: ./<name>.tar).")
    var output: String?

    @Flag(name: .long, help: "Overwrite an existing output file.")
    var force: Bool = false

    @Option(name: .long, help: "Kernel image for the builder VM (default: MSL home / ./kernel).")
    var kernel: String?

    @Option(name: .long, help: "Builder initramfs (default: MSL home / ./builder-initramfs.cpio).")
    var builderInitramfs: String?

    func run() throws {
        let home = MSLHome.resolve()
        let registry = try Registry.load(from: home.registryURL)
        let plan = try ExportPlan.make(
            name: name, output: output, force: force, registry: registry, home: home)
        let env = ProcessInfo.processInfo.environment
        let options = InstallOptions(
            kernelPath: home.resolvePath(
                flag: kernel, homeCandidate: home.kernelPath, devEnv: env["MSL_KERNEL"],
                devDefault: "kernel"),
            builderInitramfsPath: home.resolvePath(
                flag: builderInitramfs, homeCandidate: home.builderInitramfsPath, devEnv: nil,
                devDefault: "builder-initramfs.cpio"))
        try ExportDriver(home: home).export(plan: plan, options: options)
        let size = try Self.fileSize(plan.outputURL)
        print("exported \(name) -> \(plan.outputURL.path) (\(size) bytes)")
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? UInt64 else {
            throw MSLError.io("cannot stat output: \(url.path)")
        }
        return size
    }
}
