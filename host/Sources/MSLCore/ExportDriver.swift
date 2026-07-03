import Darwin
import Foundation

/// A validated export request. `make` performs every check that does not need a
/// VM (name exists, output path shape/parent/overwrite), so the command layer
/// validates before any boot.
public struct ExportPlan: Sendable, Equatable {
    public let name: String
    public let imageURL: URL
    public let outputURL: URL
    /// True when the output ends `.msl`: append a rendered conf to the archive.
    public let bundle: Bool
    /// The registry entry's login user, copied only in bundle mode.
    public let defaultUser: String?

    /// Validate a request: name must name an installed distro; the output
    /// defaults to `./<name>.tar`, must end in `.tar` or `.msl`, its parent must
    /// exist and be writable, and an existing file is refused unless `force`.
    public static func make(
        name: String, output: String?, force: Bool, registry: Registry, home: MSLHome
    ) throws -> ExportPlan {
        guard Registry.isValidName(name) else {
            throw MSLError.invalidArgument("invalid distro name: \(name)")
        }
        guard let entry = registry.entry(name: name) else {
            throw MSLError.invalidArgument("no such distro: \(name) (see 'msl list')")
        }
        let resolved = try resolveOutput(name: name, output: output, force: force)
        let bundleUser = try resolved.bundle ? validatedDefaultUser(entry, name: name) : nil
        return ExportPlan(
            name: name, imageURL: home.imageURL(name: name), outputURL: resolved.url,
            bundle: resolved.bundle, defaultUser: bundleUser)
    }

    /// A hand-edited registry could hold a default-user with a newline or other
    /// INI-breaking bytes; reject it before it is rendered into a bundle conf.
    private static func validatedDefaultUser(_ entry: DistroEntry, name: String) throws -> String? {
        assert(!name.isEmpty, "name validated by caller")
        guard let user = entry.defaultUser else { return nil }
        guard Registry.isValidUser(user) else {
            throw MSLError.configuration(
                "registry default-user for \(name) is invalid; fix with 'msl config'")
        }
        return user
    }

    private static func resolveOutput(
        name: String, output: String?, force: Bool
    ) throws -> (url: URL, bundle: Bool) {
        assert(!name.isEmpty, "name validated by caller")
        let url = URL(fileURLWithPath: output ?? "./\(name).tar")
        let ext = url.pathExtension.lowercased()
        guard ext == "tar" || ext == "msl" else {
            throw MSLError.invalidArgument("output must end in .tar or .msl: \(url.path)")
        }
        let parent = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue
        else {
            throw MSLError.invalidArgument("output directory does not exist: \(parent.path)")
        }
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw MSLError.invalidArgument("output directory not writable: \(parent.path)")
        }
        guard force || !fileManager.fileExists(atPath: url.path) else {
            throw MSLError.invalidArgument("output exists (use --force to overwrite): \(url.path)")
        }
        assert(ext == "tar" || ext == "msl", "extension validated above")
        return (url, ext == "msl")
    }
}

/// Executes an `ExportPlan`: boots the builder VM read-only over the distro
/// image, tars its root into a writable staging share, then moves the tarball to
/// the requested output. All VM work is confined here; `ExportPlan.make` stays
/// pure. Never calls `exit`.
public final class ExportDriver {
    private let home: MSLHome

    public init(home: MSLHome) {
        self.home = home
    }

    /// Tar the distro's filesystem to `plan.outputURL`. The staging directory is
    /// this method's to clean; on any throw no partial file is left at the output.
    public func export(plan: ExportPlan, options: InstallOptions) throws {
        assert(!plan.name.isEmpty, "plan name validated by make")
        try home.ensureDirectories()
        try probeInUse(plan: plan)
        let stagingDir = try makeStagingDir()
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        if plan.bundle {
            try writeBundleMeta(plan: plan, stagingDir: stagingDir)
        }
        try runExporter(plan: plan, stagingDir: stagingDir, options: options)
        let produced = stagingDir.appendingPathComponent("export.tar")
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw MSLError.configuration("exporter produced no tarball for \(plan.name)")
        }
        try moveResult(from: produced, to: plan.outputURL)
    }

    /// Acquire then immediately release the image lock: a held lock means a VM
    /// has the image attached, so exporting would read an inconsistent ext4.
    private func probeInUse(plan: ExportPlan) throws {
        assert(!plan.name.isEmpty, "plan name validated by make")
        let path = plan.imageURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw MSLError.io("image does not exist: \(path)")
        }
        do {
            let lock = try ImageLock.acquire(path: path)
            withExtendedLifetime(lock) {}
        } catch {
            throw MSLError.configuration(
                "'\(plan.name)' is in use (VM running?); run 'msl stop' first")
        }
    }

    /// Render the conf from the registry values into the writable staging share
    /// as `meta/etc/msl-distribution.conf`; the in-guest script appends it.
    private func writeBundleMeta(plan: ExportPlan, stagingDir: URL) throws {
        assert(plan.bundle, "meta is only written for bundle exports")
        assert(!plan.name.isEmpty, "plan name validated by make")
        let confDir = stagingDir.appendingPathComponent("meta/etc")
        try FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        let confURL = confDir.appendingPathComponent("msl-distribution.conf")
        let contents = BundleMeta.render(name: plan.name, defaultUser: plan.defaultUser)
        guard let data = contents.data(using: .utf8) else {
            throw MSLError.io("cannot encode bundle conf for \(plan.name)")
        }
        try data.write(to: confURL)
    }

    private func makeStagingDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
        else {
            throw MSLError.io("cannot create export staging dir: \(dir.path)")
        }
        return dir
    }

    /// Boot the builder VM with the image read-only and the staging share
    /// writable, run the one-shot tar script, verify its exit code, then stop.
    private func runExporter(plan: ExportPlan, stagingDir: URL, options: InstallOptions) throws {
        assert(!plan.name.isEmpty, "plan name validated by make")
        let logPath = home.logsDirectory.appendingPathComponent("export-\(plan.name).log").path
        let spec = try BootSpec(
            kernelPath: options.kernelPath, initramfsPath: options.builderInitramfsPath,
            commandLine: "console=hvc0", cpuCount: options.cpus, memoryMiB: options.memoryMiB,
            consoleLogPath: logPath, execCommand: nil, timeout: options.bootTimeout,
            diskPaths: [plan.imageURL.path],
            shares: [ShareSpec(tag: "staging", hostPath: stagingDir.path, readOnly: false)])
        let host = VMHost(spec: spec)
        try host.startAndWait(onStop: { _, _ in })
        defer { _ = host.stopAndWait() }
        let control = try ControlClient(client: try host.connectAndWait())
        defer { control.close() }
        _ = try control.ping()
        let receive = Double(options.execTimeoutMs) / 1000.0 + 15
        let result = try control.exec(
            argv: ["/bin/sh", "-c", Self.exportScript(bundle: plan.bundle)],
            timeoutMs: options.execTimeoutMs, receiveTimeout: receive)
        guard result.exitCode == 0 else {
            throw MSLError.configuration(
                "exporter script failed (exit \(result.exitCode)); console log: \(logPath)")
        }
    }

    /// Land `src` at `dst` by staging next to it and renaming over it, so a
    /// pre-existing (`--force`) output is only ever replaced by a complete file.
    private func moveResult(from src: URL, to dst: URL) throws {
        assert(!src.path.isEmpty, "source path must not be empty")
        assert(!dst.path.isEmpty, "destination path must not be empty")
        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).\(UUID().uuidString).tmp")
        try stageOnDestVolume(src, at: tmp)
        guard Darwin.rename(tmp.path, dst.path) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw MSLError.io("rename onto \(dst.path) failed (errno=\(err))")
        }
    }

    /// Rename `src` to `tmp` (same-volume fast path) or copy across volumes,
    /// removing a partial `tmp` on failure; `src` cleanup is best-effort.
    private func stageOnDestVolume(_ src: URL, at tmp: URL) throws {
        assert(!src.path.isEmpty, "source path must not be empty")
        assert(!tmp.path.isEmpty, "tmp path must not be empty")
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: src, to: tmp)
        } catch {
            do {
                try fileManager.copyItem(at: src, to: tmp)
            } catch {
                try? fileManager.removeItem(at: tmp)
                throw error
            }
            try? fileManager.removeItem(at: src)
        }
    }

    /// One-shot in-guest export: mount the image read-only, tar its root
    /// (xattrs + numeric owners, minus lost+found) into the staging share. In
    /// bundle mode the create excludes any conf baked into the rootfs and
    /// appends the host-rendered one (root-owned, constant member path), so the
    /// archive holds exactly one conf member — never a stale duplicate.
    static func exportScript(bundle: Bool) -> String {
        let excludeConf = bundle ? " --exclude=./etc/msl-distribution.conf" : ""
        var lines = [
            "set -euf",
            "export PATH=/usr/sbin:/sbin:/usr/bin:/bin",
            "mount -t ext4 -o ro /dev/vda /mnt",
            "/usr/bin/tar -cpf /run/msl/staging/export.tar \\",
            "    --xattrs --xattrs-include=* --numeric-owner \\",
            "    --exclude=./lost+found\(excludeConf) -C /mnt .",
        ]
        if bundle {
            lines.append("/usr/bin/tar -rpf /run/msl/staging/export.tar \\")
            lines.append("    --owner=0 --group=0 --mode=0644 \\")
            lines.append("    -C /run/msl/staging/meta ./etc/msl-distribution.conf")
        }
        lines.append("sync")
        lines.append("umount /mnt")
        assert(lines.count >= 8, "export script must retain its core steps")
        assert(!lines[0].isEmpty, "first line must not be empty")
        return lines.joined(separator: "\n")
    }
}
