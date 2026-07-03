import CMSLSys
import Darwin
import Foundation

/// Whole-file advisory lock (flock LOCK_EX) on `$MSL_HOME/msld.lock`, held for a
/// daemon's lifetime. It is THE ownership primitive: the winner alone may unlink
/// a stale socket, rebind, and unlink the socket/PID on teardown; a second
/// daemon fails the non-blocking flock and refuses. Mirrors `ImageLock`.
public final class DaemonLock: @unchecked Sendable {
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

    /// Release the lock (idempotent). Process exit also releases it.
    public func release() {
        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
        fd = -1
    }

    /// Acquire the daemon lock, creating the file 0600. A held lock means another
    /// daemon owns this MSL home, surfaced as "daemon already running".
    public static func acquire(path: String) throws -> DaemonLock {
        precondition(!path.isEmpty, "lock path must not be empty")
        let fd = Darwin.open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw MSLError.io("cannot open daemon lockfile: \(path) (errno=\(errno))")
        }
        guard msl_flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            if err == EWOULDBLOCK {
                throw MSLError.configuration("daemon already running (lock: \(path))")
            }
            throw MSLError.io("flock failed for \(path) (errno=\(err))")
        }
        return DaemonLock(fd: fd, path: path)
    }
}
