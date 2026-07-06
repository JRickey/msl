import ArgumentParser
import Darwin
import Foundation
import MSLCore
import MSLFSWire

/// `msl unmount [<distro>]`: run `/sbin/umount` here (so errors reach this
/// terminal), then tell the daemon to drop its mount state and release the
/// activity hold. `--force` uses `umount -f` and clears state regardless.
struct UnmountCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unmount",
        abstract: "Unmount a distro's Finder filesystem view.")

    @Argument(help: "Distro to unmount (default: the only mounted distro).")
    var name: String?

    @Flag(name: .long, help: "Force unmount even if files are open (umount -f).")
    var force: Bool = false

    func run() throws {
        let home = MSLHome.resolve()
        guard DaemonClient.isRunning(home) else {
            try forceUnmountWithoutDaemon()
            return
        }
        let entry = try resolveMount(home)
        let result = Subprocess.run(
            "/sbin/umount", force ? ["-f", entry.mountpoint] : [entry.mountpoint])
        if result.status != 0 && !force {
            throw MSLError.io("umount failed (exit \(result.status)): \(result.stderr)")
        }
        try DaemonClient.mountUnmount(home, name: entry.name, force: force)
        print("unmounted \(entry.name)")
    }

    /// With the daemon down, `--force` still clears a stranded kernel mount so a
    /// daemon crash cannot wedge Finder. Needs an explicit distro name — there is
    /// no daemon state to resolve "the only mount" against.
    private func forceUnmountWithoutDaemon() throws {
        guard force, let name else {
            print("daemon not running")
            return
        }
        guard let mountpoint = FSMountpoint.directory(distro: name) else {
            throw MSLError.configuration("'\(name)' is not a valid distro name")
        }
        guard Self.isMSLFSMounted(at: mountpoint) else {
            print("no mslfs mount at \(mountpoint)")
            return
        }
        let result = Subprocess.run("/sbin/umount", ["-f", mountpoint])
        guard result.status == 0 else {
            throw MSLError.io("umount -f failed (exit \(result.status)): \(result.stderr)")
        }
        print("unmounted \(name)")
    }

    /// True only when an `mslfs` volume is mounted exactly at `mountpoint`, so a
    /// daemon-down force unmount never tears down another filesystem that happens
    /// to occupy the reserved path.
    private static func isMSLFSMounted(at mountpoint: String) -> Bool {
        assert(!mountpoint.isEmpty, "mountpoint must not be empty")
        assert(mountpoint.hasPrefix("/"), "mountpoint must be absolute")
        var buf = statfs()
        let rc = mountpoint.withCString { path in statfs(path, &buf) }
        guard rc == 0 else { return false }
        let fstype = withUnsafeBytes(of: buf.f_fstypename) { raw -> String in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        return fstype == FSProto.shortName
    }

    /// Resolve which mount to unmount: the named one, or the sole mount when no
    /// name is given. Errors clearly when the choice is ambiguous or absent.
    private func resolveMount(_ home: MSLHome) throws -> MountEntry {
        let mounts = try DaemonClient.mountStatus(home).mounts
        guard !mounts.isEmpty else { throw MSLError.configuration("no distro is mounted") }
        if let name {
            guard let match = mounts.first(where: { $0.name == name }) else {
                throw MSLError.configuration("'\(name)' is not mounted")
            }
            return match
        }
        guard mounts.count == 1, let only = mounts.first else {
            let names = mounts.map { $0.name }.joined(separator: ", ")
            throw MSLError.configuration("multiple distros mounted (\(names)); name one")
        }
        return only
    }
}
