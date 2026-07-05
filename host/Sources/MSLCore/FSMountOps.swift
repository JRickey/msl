import Darwin
import Foundation

/// Kernel-level mount queries and unmounts for the daemon's cleanup paths. The
/// interactive `/sbin/mount -F` and `/sbin/umount` stay in the CLI so their
/// errors reach the terminal; the daemon uses these for reconciliation and the
/// forced-unmount safety net on teardown.
public enum FSMountOps {
    /// Mountpoints of `fstype` (default `mslfs`) currently mounted under `base`.
    public static func discoverMounts(
        base: String, fstype: String = FSProto.shortName
    ) -> [String] {
        precondition(!base.isEmpty, "base path must not be empty")
        precondition(!fstype.isEmpty, "fstype must not be empty")
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let entries = buffer else { return [] }
        var result: [String] = []
        for idx in 0..<Int(count) {  // bounded: count returned by getmntinfo
            let entry = entries[idx]
            guard fstypeName(entry) == fstype else { continue }
            let mountpoint = mountOnName(entry)
            if mountpoint == base || mountpoint.hasPrefix(base + "/") { result.append(mountpoint) }
        }
        return result.sorted()
    }

    /// Unmount `mountpoint` via the `unmount(2)` syscall (force adds `MNT_FORCE`).
    /// Returns true on success or when nothing is mounted there (EINVAL/ENOENT).
    @discardableResult
    public static func forceUnmount(mountpoint: String, force: Bool) -> Bool {
        precondition(!mountpoint.isEmpty, "mountpoint must not be empty")
        let flags = force ? MNT_FORCE : 0
        if Darwin.unmount(mountpoint, flags) == 0 { return true }
        let err = errno
        return err == EINVAL || err == ENOENT
    }

    private static func fstypeName(_ entry: statfs) -> String {
        var entry = entry
        return withUnsafePointer(to: &entry.f_fstypename) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
    }

    private static func mountOnName(_ entry: statfs) -> String {
        var entry = entry
        return withUnsafePointer(to: &entry.f_mntonname) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
