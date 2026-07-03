import CMSLSys
import Darwin
import Foundation

/// Advisory whole-file lock (flock LOCK_EX) held for a VM's lifetime so two msl
/// processes cannot attach the same read-write disk image and corrupt its ext4.
/// VZ opens its own descriptor; this fd exists purely to carry the lock.
public final class ImageLock: @unchecked Sendable {
    private var fd: Int32
    public let path: String

    private init(fd: Int32, path: String) {
        precondition(fd >= 0, "lock fd must be valid")
        self.fd = fd
        self.path = path
    }

    deinit {
        if fd >= 0 { _ = Darwin.close(fd) }
    }

    /// Lock a sidecar `<path>.lock`, NOT the image itself: Virtualization takes
    /// its own lock on the image at attach time, and a competing flock there
    /// makes the storage attachment invalid (VZErrorDomain code=2).
    public static func acquire(path: String) throws -> ImageLock {
        precondition(!path.isEmpty, "image path must not be empty")
        guard FileManager.default.fileExists(atPath: path) else {
            throw MSLError.io("image does not exist: \(path)")
        }
        let fd = Darwin.open(path + ".lock", O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw MSLError.io("cannot open image lockfile: \(path).lock (errno=\(errno))")
        }
        guard msl_flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            if err == EWOULDBLOCK {
                throw MSLError.configuration("image in use by another msl process: \(path)")
            }
            throw MSLError.io("flock failed for \(path) (errno=\(err))")
        }
        return ImageLock(fd: fd, path: path)
    }
}
