import Darwin
import Foundation

/// AF_UNIX stream-socket helpers for the local control plane: bind (with stale
/// detection and second-daemon refusal), dial, and accept. Descriptors are raw
/// blocking fds handed to `VsockClient` for framing, mirroring the vsock path.
public enum LocalSocket {
    /// Bind a listening socket at `path`, creating it 0600. The caller must
    /// already hold the daemon lock (the ownership primitive), so any existing
    /// socket file is stale and is unlinked before binding. Returns the fd.
    public static func bindListener(path: String, backlog: Int32 = 64) throws -> Int32 {
        precondition(!path.isEmpty, "socket path must not be empty")
        precondition(backlog > 0, "backlog must be positive")
        if pathExists(path) {
            _ = Darwin.unlink(path)
        }
        return try bindFresh(path: path, backlog: backlog)
    }

    /// Connect to the daemon socket and return an owned blocking fd. Throws
    /// `MSLError.io` when nothing is listening (ENOENT/ECONNREFUSED).
    public static func dial(path: String) throws -> Int32 {
        precondition(!path.isEmpty, "socket path must not be empty")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MSLError.io("socket() failed: errno=\(errno)") }
        var addr = sockaddr_un()
        try fill(&addr, path: path)
        let rc = connectSocket(fd, &addr)
        guard rc == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            throw MSLError.io("connect(\(path)) failed: errno=\(err)")
        }
        return fd
    }

    /// True when a client can connect to `path` (a daemon is accepting there).
    public static func probeAlive(_ path: String) -> Bool {
        guard let fd = try? dial(path: path) else { return false }
        _ = Darwin.close(fd)
        return true
    }

    /// Accept one connection, returning an owned blocking fd. Retries on EINTR.
    public static func accept(listener: Int32) throws -> Int32 {
        precondition(listener >= 0, "listener fd must be valid")
        for _ in 0..<64 {  // bounded: only EINTR loops; any other result returns
            let fd = Darwin.accept(listener, nil, nil)
            if fd >= 0 { return fd }
            if errno == EINTR { continue }
            throw MSLError.io("accept failed: errno=\(errno)")
        }
        throw MSLError.io("accept interrupted repeatedly")
    }

    private static func bindFresh(path: String, backlog: Int32) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MSLError.io("socket() failed: errno=\(errno)") }
        var addr = sockaddr_un()
        try fill(&addr, path: path)
        guard bindSocket(fd, &addr) == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            throw MSLError.io("bind(\(path)) failed: errno=\(err)")
        }
        guard Darwin.chmod(path, 0o600) == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            throw MSLError.io("chmod 0600 \(path) failed: errno=\(err)")
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            throw MSLError.io("listen(\(path)) failed: errno=\(err)")
        }
        return fd
    }

    private static func pathExists(_ path: String) -> Bool {
        return Darwin.access(path, F_OK) == 0
    }

    /// Populate `sun_family`/`sun_len`/`sun_path`; rejects an over-long path
    /// (sockaddr_un has a fixed 104-byte path field on Darwin).
    private static func fill(_ addr: inout sockaddr_un, path: String) throws {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            throw MSLError.configuration("socket path too long (max \(capacity - 1)): \(path)")
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for idx in 0..<bytes.count {  // bounded: bytes.count < capacity
                    dst[idx] = CChar(bitPattern: bytes[idx])
                }
                dst[bytes.count] = 0
            }
        }
    }

    private static func bindSocket(_ fd: Int32, _ addr: inout sockaddr_un) -> Int32 {
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
    }

    private static func connectSocket(_ fd: Int32, _ addr: inout sockaddr_un) -> Int32 {
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
    }
}
