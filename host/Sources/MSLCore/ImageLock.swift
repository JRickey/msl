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

    /// Open `path` O_RDWR and take a non-blocking exclusive advisory lock.
    /// Throws if the file cannot be opened or another msl process holds the lock.
    public static func acquire(path: String) throws -> ImageLock {
        precondition(!path.isEmpty, "image path must not be empty")
        let fd = Darwin.open(path, O_RDWR)
        guard fd >= 0 else {
            throw MSLError.io("cannot open image for locking: \(path) (errno=\(errno))")
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
