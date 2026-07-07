import ArgumentParser
import Foundation
import MSLCore

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract:
            "Install a distro from the catalog or from an image, root tarball, or .msl bundle.")

    @Argument(
        help:
            "Catalog selector (ubuntu or ubuntu@24.04), or distro name when --from is passed."
    )
    var selectorOrName: String?

    @Option(
        name: .long,
        help:
            "Source: an .img ext4 image, a .tar.xz/.tar.gz/.tar root tarball, or a .msl bundle.")
    var from: String?

    @Option(name: .long, help: "Installed distro name for catalog installs.")
    var name: String?

    @Option(name: .long, help: "Image size in GiB for a tarball build (ignored for .img).")
    var sizeGib: Int = 8

    @Option(name: .long, help: "Kernel image for the builder VM (default: MSL home / ./kernel).")
    var kernel: String?

    @Option(name: .long, help: "Builder initramfs (default: MSL home / ./builder-initramfs.cpio).")
    var builderInitramfs: String?

    func run() throws {
        let home = MSLHome.resolve()
        if let from {
            try runFileInstall(home: home, from: from)
            return
        }
        try runCatalogInstall(home: home)
    }

    private func runFileInstall(home: MSLHome, from: String) throws {
        if name != nil {
            throw MSLError.invalidArgument("--name is only valid for catalog installs")
        }
        Self.note("install: reading source \(from)")
        let registry = try Registry.load(from: home.registryURL)
        let existing = registry.distros.map { $0.name }
        let plan = try Self.makePlan(
            name: selectorOrName, from: from, sizeGiB: sizeGib, existing: existing)
        Self.note("install: building image for \(plan.name)")
        let entry = try install(plan: plan, home: home)
        Self.note("install: registered \(entry.name)")
        let launcher = try LauncherStore(home: home).create(
            name: entry.name, mode: .shell, replace: true)
        Self.note("launcher: created \(launcher.path)")
        try printInstall(entry, home: home)
    }

    private func runCatalogInstall(home: MSLHome) throws {
        guard let selector = selectorOrName else {
            throw MSLError.invalidArgument(
                "missing selector; use 'msl catalog list' or pass --from")
        }
        Self.note("catalog: resolving \(selector)")
        let catalog = try Catalog.loadEmbedded()
        let resolved = try catalog.resolve(selector: selector)
        let installName = name ?? resolved.family.name
        Self.note(
            "catalog: selected \(resolved.family.friendlyName) \(resolved.version.version)"
        )
        Self.note("install: target name \(installName)")
        let registry = try Registry.load(from: home.registryURL)
        try Self.validateCatalogName(installName, registry: registry)
        let reporter = CatalogProgressReporter()
        let sourceURL = try CatalogDownloader(home: home).fetch(resolved) { progress in
            reporter.emit(progress)
        }
        let launcherIcon = try prepareLauncherIcon(
            home: home, resolved: resolved, reporter: reporter)
        let source = InstallSource.tarball(sourceURL, resolved.artifact.compression)
        let plan = try InstallPlan.make(
            name: installName, source: source, sizeGiB: resolved.version.imageSizeGiB,
            existingNames: registry.distros.map { $0.name },
            defaultUser: resolved.version.defaultUser,
            catalogSelector: resolved.selector)
        Self.note("install: building image for \(installName)")
        let entry = try install(plan: plan, home: home)
        Self.note("install: registered \(entry.name)")
        let launcher = try LauncherStore(home: home).create(
            name: entry.name, mode: .shell, replace: true, icon: launcherIcon)
        Self.note("launcher: created \(launcher.path)")
        try printInstall(entry, home: home)
    }

    private func prepareLauncherIcon(
        home: MSLHome, resolved: CatalogResolved, reporter: CatalogProgressReporter
    ) throws -> URL? {
        guard resolved.version.icon != nil else {
            Self.note("launcher: no catalog icon; generating fallback icon")
            return nil
        }
        Self.note("catalog: preparing launcher icon")
        return try CatalogIconStore(home: home).icon(for: resolved) { progress in
            reporter.emit(progress)
        }
    }

    private static func validateCatalogName(_ name: String, registry: Registry) throws {
        guard Registry.isValidName(name) else {
            throw MSLError.invalidArgument("invalid distro name (^[a-z][a-z0-9-]{0,31}$): \(name)")
        }
        guard registry.entry(name: name) == nil else {
            throw MSLError.configuration("distro already registered: \(name); pass --name")
        }
    }

    private func install(plan: InstallPlan, home: MSLHome) throws -> DistroEntry {
        let env = ProcessInfo.processInfo.environment
        let options = InstallOptions(
            kernelPath: home.resolvePath(
                flag: kernel, homeCandidate: home.kernelPath, devEnv: env["MSL_KERNEL"],
                devDefault: "kernel"),
            builderInitramfsPath: home.resolvePath(
                flag: builderInitramfs, homeCandidate: home.builderInitramfsPath, devEnv: nil,
                devDefault: "builder-initramfs.cpio"))
        return try InstallDriver(home: home).install(plan: plan, options: options)
    }

    private func printInstall(_ entry: DistroEntry, home: MSLHome) throws {
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

    private static func note(_ message: String) {
        assert(!message.isEmpty, "progress note must not be empty")
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private final class CatalogProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private var inlineActive = false

    func emit(_ progress: CatalogDownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        switch progress {
        case .checkingCache(let path):
            finishInline()
            line("catalog: checking cache \(path)")
        case .cacheHit(let path):
            finishInline()
            line("catalog: cache hit; SHA256 already verified at \(path)")
        case .startingDownload(let url, let bytes):
            finishInline()
            line("catalog: downloading \(url)")
            line("catalog: expected size \(Self.humanBytes(bytes))")
        case .downloading(let received, let total):
            draw(received: received, total: total)
        case .verifying(_, let sha256):
            finishInline()
            line("catalog: verifying SHA256 \(sha256)")
        case .ready(let path):
            finishInline()
            line("catalog: verified download ready at \(path)")
        }
    }

    private func draw(received: UInt64, total: UInt64?) {
        guard let total, total > 0 else {
            line("catalog: downloaded \(Self.humanBytes(received))")
            return
        }
        let percent = min(100, Int((Double(received) / Double(total)) * 100))
        guard percent != lastPercent else { return }
        lastPercent = percent
        inlineActive = true
        let width = 30
        let filled = min(width, max(0, percent * width / 100))
        let bar =
            String(repeating: "=", count: filled)
            + String(repeating: "-", count: width - filled)
        let text =
            "\rcatalog: download [\(bar)] \(percent)% "
            + "\(Self.humanBytes(received))/\(Self.humanBytes(total))"
        FileHandle.standardError.write(Data(text.utf8))
    }

    private func line(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func finishInline() {
        guard inlineActive else { return }
        FileHandle.standardError.write(Data("\n".utf8))
        inlineActive = false
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f%@" : "%.1f%@", value, units[unit])
    }
}
