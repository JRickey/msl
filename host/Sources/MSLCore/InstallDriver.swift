import CMSLSys
import Darwin
import Foundation

/// Compression of a root tarball; selects the GNU tar extract flag.
public enum TarCompression: String, Codable, Sendable, Equatable {
    case xz
    case gzip
    case none

    var tarExtractFlag: String {
        switch self {
        case .xz: return "J"
        case .gzip: return "z"
        case .none: return ""
        }
    }

    /// Fixed staging basename by type: the tarball is always shared under this
    /// constant so no user-controlled string is ever interpolated into the
    /// builder script (only the regex-validated name/hostname are).
    public var stagedFilename: String {
        switch self {
        case .xz: return "rootfs.tar.xz"
        case .gzip: return "rootfs.tar.gz"
        case .none: return "rootfs.tar"
        }
    }
}

/// Where an install's bytes come from: an existing ext4 image to copy, or a
/// root tarball to unpack inside the builder VM.
public enum InstallSource: Sendable, Equatable {
    case image(URL)
    case tarball(URL, TarCompression)
}

/// A validated install request. `make` performs every check that does not need
/// a VM, so argument validation is unit-testable without booting anything.
public struct InstallPlan: Sendable, Equatable {
    public let name: String
    public let hostname: String
    public let source: InstallSource
    public let sizeGiB: Int
    /// Login user to seed on the registry entry (nil = root); from a bundle conf.
    public let defaultUser: String?
    /// Catalog selector that produced this install, when applicable.
    public let catalogSelector: String?

    public static let minSizeGiB = 1
    public static let maxSizeGiB = 512

    /// Validate a request: name grammar, uniqueness, source existence + type,
    /// size bounds, and (if present) the default-user grammar. The distro's
    /// hostname is seeded to its name. `.msl` sources supply their sniffed
    /// compression via `bundleCompression` (the CLI sniffs before calling).
    public static func make(
        name: String, fromPath: String, sizeGiB: Int, existingNames: [String],
        bundleCompression: TarCompression? = nil, defaultUser: String? = nil,
        catalogSelector: String? = nil
    ) throws -> InstallPlan {
        let source = try classify(fromPath, bundleCompression: bundleCompression)
        return try make(
            name: name, source: source, sizeGiB: sizeGiB, existingNames: existingNames,
            defaultUser: defaultUser, catalogSelector: catalogSelector)
    }

    public static func make(
        name: String, source: InstallSource, sizeGiB: Int, existingNames: [String],
        defaultUser: String? = nil, catalogSelector: String? = nil
    ) throws -> InstallPlan {
        assert(minSizeGiB <= maxSizeGiB, "size bounds must be ordered")
        guard Registry.isValidName(name) else {
            throw MSLError.invalidArgument("invalid distro name (^[a-z][a-z0-9-]{0,31}$): \(name)")
        }
        guard !existingNames.contains(name) else {
            throw MSLError.configuration("distro already registered: \(name)")
        }
        guard (minSizeGiB...maxSizeGiB).contains(sizeGiB) else {
            throw MSLError.invalidArgument(
                "size-gib must be \(minSizeGiB)...\(maxSizeGiB): \(sizeGiB)")
        }
        try validateReadable(source)
        if let user = defaultUser, !Registry.isValidUser(user) {
            throw MSLError.invalidArgument(
                "invalid default-user (^[a-z_][a-z0-9_-]{0,31}$): \(user)")
        }
        if let catalogSelector, !Catalog.isValidSelectorSyntax(catalogSelector) {
            throw MSLError.invalidArgument("invalid catalog selector: \(catalogSelector)")
        }
        return InstallPlan(
            name: name, hostname: name, source: source, sizeGiB: sizeGiB,
            defaultUser: defaultUser, catalogSelector: catalogSelector)
    }

    private static func validateReadable(_ source: InstallSource) throws {
        let path: String
        switch source {
        case .image(let url), .tarball(let url, _):
            path = url.path
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw MSLError.invalidArgument("--from not readable: \(path)")
        }
    }

    private static func classify(
        _ path: String, bundleCompression: TarCompression?
    ) throws -> InstallSource {
        assert(!path.isEmpty, "path must not be empty")
        let lower = path.lowercased()
        let url = URL(fileURLWithPath: path)
        if lower.hasSuffix(".img") { return .image(url) }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return .tarball(url, .xz) }
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarball(url, .gzip) }
        if lower.hasSuffix(".tar") { return .tarball(url, .none) }
        if lower.hasSuffix(".msl") {
            guard let compression = bundleCompression else {
                throw MSLError.invalidArgument(
                    "internal: .msl source needs a sniffed compression: \(path)")
            }
            return .tarball(url, compression)
        }
        throw MSLError.invalidArgument(
            "unsupported --from type (want .img, .tar.xz, .tar.gz, .tar, or .msl): \(path)")
    }
}

/// Tunables for the builder VM. Defaults mirror tools/mk-rootfs.sh.
public struct InstallOptions: Sendable {
    public let kernelPath: String
    public let builderInitramfsPath: String
    public let cpus: Int
    public let memoryMiB: UInt64
    public let bootTimeout: Double
    public let execTimeoutMs: UInt64

    public init(
        kernelPath: String, builderInitramfsPath: String, cpus: Int = 4,
        memoryMiB: UInt64 = 4096, bootTimeout: Double = 120, execTimeoutMs: UInt64 = 600_000
    ) {
        precondition(!kernelPath.isEmpty, "kernel path must not be empty")
        precondition(!builderInitramfsPath.isEmpty, "builder initramfs path must not be empty")
        self.kernelPath = kernelPath
        self.builderInitramfsPath = builderInitramfsPath
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.bootTimeout = bootTimeout
        self.execTimeoutMs = execTimeoutMs
    }
}

/// Executes an `InstallPlan`: materializes the image (copy or builder-VM build),
/// then registers it. All VM work is confined here; `InstallPlan.make` stays
/// pure so the command layer validates before any boot. Never calls `exit`.
public final class InstallDriver {
    private let home: MSLHome
    private let bytesPerGiB: UInt64 = 1024 * 1024 * 1024

    public init(home: MSLHome) {
        self.home = home
    }

    /// Materialize + register the distro; returns the created registry entry.
    /// One cleanup owner covers the whole flow: any throw after the image is
    /// created — including a Registry load/add/save failure — removes the image
    /// and its sidecar so a failed install never leaves an orphan behind.
    public func install(plan: InstallPlan, options: InstallOptions) throws -> DistroEntry {
        try home.ensureDirectories()
        let imageURL = home.imageURL(name: plan.name)
        var committed = false
        defer { if !committed { cleanupArtifacts(imageURL) } }
        switch plan.source {
        case .image(let src):
            try copyImage(from: src, to: imageURL)
        case .tarball(let src, let compression):
            try buildImage(
                plan: plan, tarball: src, compression: compression,
                to: imageURL, options: options)
        }
        if let user = plan.defaultUser {
            assert(Registry.isValidUser(user), "plan default-user must be pre-validated")
            guard Registry.isValidUser(user) else {
                throw MSLError.invalidArgument("invalid default-user in plan: \(user)")
            }
        }
        let entry = DistroEntry(
            name: plan.name, image: imageURL.lastPathComponent, hostname: plan.hostname,
            createdAt: Self.timestamp(), defaultUser: plan.defaultUser,
            catalogSelector: plan.catalogSelector)
        var registry = try Registry.load(from: home.registryURL)
        try registry.add(entry)
        try registry.save(to: home.registryURL)
        committed = true
        return entry
    }

    private func cleanupArtifacts(_ imageURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: imageURL)
        try? fileManager.removeItem(at: imageURL.appendingPathExtension("lock"))
    }

    /// COW clone (sparse-preserving) into the store, falling back to a plain copy
    /// across filesystems. The destination must not pre-exist a clonefile call.
    private func copyImage(from src: URL, to dst: URL) throws {
        assert(!src.path.isEmpty, "source path must not be empty")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dst.path) {
            try fileManager.removeItem(at: dst)
        }
        if msl_clonefile(src.path, dst.path) == 0 { return }
        let err = errno
        guard err == EXDEV || err == ENOTSUP else {
            throw MSLError.io("clonefile \(src.path) -> \(dst.path) failed (errno=\(err))")
        }
        try fileManager.copyItem(at: src, to: dst)
    }

    /// Build an ext4 image from a root tarball in an ephemeral builder VM: sparse
    /// image + staging share, one `sh -c` script (mkfs, extract, seed, verify).
    /// The image/sidecar cleanup on failure is owned by `install`; this owns only
    /// the ephemeral staging directory.
    private func buildImage(
        plan: InstallPlan, tarball: URL, compression: TarCompression, to imageURL: URL,
        options: InstallOptions
    ) throws {
        try createSparseImage(at: imageURL, sizeGiB: plan.sizeGiB)
        let staged = try stageTarball(tarball, compression: compression)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        try runBuilder(
            plan: plan, stagedTarball: staged, compression: compression, imageURL: imageURL,
            options: options)
    }

    /// Boot the builder VM, run the one-shot build script in the agent context,
    /// verify its exit code, then stop. Console goes to the MSL home logs dir.
    private func runBuilder(
        plan: InstallPlan, stagedTarball: URL, compression: TarCompression, imageURL: URL,
        options: InstallOptions
    ) throws {
        let stagingDir = stagedTarball.deletingLastPathComponent()
        let logPath = home.logsDirectory.appendingPathComponent("install-\(plan.name).log").path
        let spec = try BootSpec(
            kernelPath: options.kernelPath, initramfsPath: options.builderInitramfsPath,
            commandLine: "console=hvc0", cpuCount: options.cpus, memoryMiB: options.memoryMiB,
            consoleLogPath: logPath, execCommand: nil, timeout: options.bootTimeout,
            diskPaths: [imageURL.path],
            shares: [ShareSpec(tag: "staging", hostPath: stagingDir.path, readOnly: true)])
        let host = VMHost(spec: spec)
        try host.startAndWait(onStop: { _, _ in })
        defer { _ = host.stopAndWait() }
        let control = try ControlClient(client: try host.connectAndWait())
        defer { control.close() }
        _ = try control.ping()
        let script = Self.buildScript(
            tarball: stagedTarball.lastPathComponent, hostname: plan.hostname,
            tarFlag: compression.tarExtractFlag)
        let receive = Double(options.execTimeoutMs) / 1000.0 + 15
        let result = try control.exec(
            argv: ["/bin/sh", "-c", script], timeoutMs: options.execTimeoutMs,
            receiveTimeout: receive)
        guard result.exitCode == 0 else {
            throw MSLError.configuration(
                "builder script failed (exit \(result.exitCode)); console log: \(logPath)")
        }
    }

    /// Create a sparse image of `sizeGiB` GiB via ftruncate (a hole, no blocks).
    private func createSparseImage(at url: URL, sizeGiB: Int) throws {
        assert(sizeGiB > 0, "size validated by InstallPlan")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw MSLError.io("cannot create image: \(url.path)")
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw MSLError.io("cannot open image for sizing: \(url.path)")
        }
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(sizeGiB) &* bytesPerGiB)
    }

    /// Create a private temp dir and stage the tarball into it under the fixed
    /// per-type name; returns the staged file URL (its parent is shared).
    private func stageTarball(_ tarball: URL, compression: TarCompression) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Self.stage(source: tarball, compression: compression, into: dir)
    }

    /// Hardlink (or copy) `source` into `dir` under `compression.stagedFilename`.
    /// The staged name is a constant, never the source basename.
    static func stage(source: URL, compression: TarCompression, into dir: URL) throws -> URL {
        let dst = dir.appendingPathComponent(compression.stagedFilename)
        do {
            try FileManager.default.linkItem(at: source, to: dst)
        } catch {
            try FileManager.default.copyItem(at: source, to: dst)
        }
        return dst
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    /// The in-guest build script, ported from tools/mk-rootfs.sh. Runs mkfs +
    /// extract + seeding, then verifies `/sbin/init` before sync/umount.
    static func buildScript(tarball: String, hostname: String, tarFlag: String) -> String {
        return """
            set -euf
            export PATH=/usr/sbin:/sbin:/usr/bin:/bin
            T0=$(date +%s)
            echo "builder: mkfs.ext4 /dev/vda"
            /sbin/mkfs.ext4 -F -q /dev/vda
            echo "builder: [$(($(date +%s)-T0))s] mount"
            mount -t ext4 /dev/vda /mnt
            echo "builder: [$(($(date +%s)-T0))s] extract \(tarball)"
            /usr/bin/tar -x\(tarFlag)pf /run/msl/staging/\(tarball) \
                --xattrs --xattrs-include=* --numeric-owner -C /mnt
            echo "builder: [$(($(date +%s)-T0))s] seed"
            echo \(hostname) > /mnt/etc/hostname
            printf "/dev/vda / ext4 defaults 0 1\\n" > /mnt/etc/fstab
            mkdir -p /mnt/mnt/mac
            [ -d /mnt/etc/cloud ] && touch /mnt/etc/cloud/cloud-init.disabled || true
            if [ -d /mnt/etc/netplan ]; then
                printf "network:\\n  version: 2\\n  ethernets:\\n" \
                    > /mnt/etc/netplan/01-msl.yaml
                printf "    all:\\n      match: {name: \\"e*\\"}\\n      dhcp4: true\\n" \
                    >> /mnt/etc/netplan/01-msl.yaml
                chmod 600 /mnt/etc/netplan/01-msl.yaml
            fi
            /usr/sbin/chroot /mnt /usr/bin/passwd -d root || true
            [ -f /mnt/lib/systemd/system/systemd-networkd-wait-online.service ] \
                && ln -sf /dev/null \
                /mnt/etc/systemd/system/systemd-networkd-wait-online.service || true
            echo "builder: [$(($(date +%s)-T0))s] verify"
            test -x /mnt/usr/lib/systemd/systemd || test -x /mnt/sbin/init
            echo "builder: [$(($(date +%s)-T0))s] sync+umount"
            sync
            umount /mnt
            echo "builder: [$(($(date +%s)-T0))s] done"
            """
    }
}
