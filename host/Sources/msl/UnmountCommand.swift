import ArgumentParser
import Foundation
import MSLCore

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
            print("daemon not running")
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
