import ArgumentParser
import Foundation
import MSLCore
import MSLFSWire

/// `msl mount [<distro>]`: prepare the mount with the daemon, run the actual
/// `/sbin/mount -F` here so its errors reach this terminal, then commit. The
/// daemon owns the mount id/nonce and appex admission; the CLI owns the syscall.
struct MountCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mount",
        abstract: "Mount a distro's filesystem in Finder at ~/msl/<distro>.")

    @Argument(help: "Distro to mount (default: the registry default).")
    var name: String?

    @Flag(name: .long, help: "Reveal the mountpoint in Finder after mounting.")
    var reveal: Bool = false

    @Flag(name: .long, help: "Mount with writes disabled.")
    var readOnly: Bool = false

    func run() throws {
        let home = MSLHome.resolve()
        let prep = try DaemonClient.mountPrepare(home, name: name, readonly: readOnly)
        try FileManager.default.createDirectory(
            atPath: prep.mountpoint, withIntermediateDirectories: true)
        do {
            try Self.mountVolume(url: prep.url, mountpoint: prep.mountpoint)
        } catch {
            try? DaemonClient.mountUnmount(home, name: prep.name, force: true)
            throw error
        }
        try DaemonClient.mountCommit(home, name: prep.name, mountpoint: prep.mountpoint)
        print("mounted \(prep.name) at \(prep.mountpoint)")
        if reveal { Self.reveal(prep.mountpoint) }
    }

    /// FSKit generic-URL mounts accept exactly `<url> <mountpoint>`; `-o` options
    /// trigger mount(8)'s argument-count rejection, so mode travels in the URL.
    private static func mountVolume(url: String, mountpoint: String) throws {
        precondition(!url.isEmpty, "resource url must not be empty")
        precondition(!mountpoint.isEmpty, "mountpoint must not be empty")
        let result = Subprocess.run(
            "/sbin/mount", ["-F", "-t", FSProto.shortName, url, mountpoint])
        guard result.status == 0 else {
            throw MSLError.io("mount -F failed (exit \(result.status)): \(result.stderr)")
        }
    }

    private static func reveal(_ mountpoint: String) {
        assert(!mountpoint.isEmpty, "mountpoint must not be empty")
        _ = Subprocess.run("/usr/bin/open", [mountpoint])
    }
}
