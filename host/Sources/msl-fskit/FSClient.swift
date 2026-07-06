import Darwin
import Foundation
import MSLFSWire

/// One connected fs-protocol client per mounted volume. Owns the app-group UDS
/// descriptor, performs the framed `FSHello` -> `FSControlReply` handshake, and
/// serializes every request/reply round trip under a lock because FSKit drives
/// ops from many threads while the guest serves one at a time. Any transport
/// failure marks the client dead; every later op then fails fast with `ENODEV`.
final class FSClient {
    private let lock = NSLock()
    private let opTimeout = 15.0
    private var fd: Int32 = -1
    private var nextID: UInt64 = 0
    private var dead = false

    func connect(distro: String, mountID: String, nonce: String, readonly: Bool) throws {
        guard !distro.isEmpty else {
            throw FSProto.PosixError(errno: EINVAL, message: "empty distro")
        }
        lock.lock()
        defer { lock.unlock() }
        assert(fd < 0, "connect must run once per client")
        guard let path = Self.socketPath() else {
            throw FSProto.PosixError(errno: ENODEV, message: "no app-group container")
        }
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw FSProto.PosixError(errno: errno, message: "socket() failed") }
        guard Self.setNoSigPipe(sock), Self.applyTimeout(sock, SO_SNDTIMEO, opTimeout),
            Self.applyTimeout(sock, SO_RCVTIMEO, opTimeout)
        else {
            let savedErrno = errno
            _ = Darwin.close(sock)
            throw FSProto.PosixError(errno: savedErrno == 0 ? EIO : savedErrno, message: "sockopt")
        }
        guard Self.connectUDS(sock, path: path) else {
            let savedErrno = errno
            _ = Darwin.close(sock)
            throw FSProto.PosixError(
                errno: savedErrno == 0 ? ENODEV : savedErrno, message: "connect")
        }
        fd = sock
        try handshake(distro: distro, mountID: mountID, nonce: nonce, readonly: readonly)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        markDeadLocked()
    }

    func roundTrip(_ request: FSProto.Request) throws -> FSProto.ReplyBody {
        lock.lock()
        defer { lock.unlock() }
        guard !dead, fd >= 0 else {
            throw FSProto.PosixError(errno: ENODEV, message: "channel dead")
        }
        nextID &+= 1
        let id = nextID
        let op = request.op
        do {
            try FSFrame.writeFrame(fd, FSProto.RequestFrame(id: id, request: request).encode())
            let reply = try FSProto.ReplyFrame.decode(FSFrame.readFrame(fd))
            guard reply.id == id, reply.op == op else {
                markDeadLocked()
                throw FSProto.PosixError(errno: EIO, message: "reply id/op mismatch")
            }
            switch reply.result {
            case .success(let body): return body
            case .failure(let guestError): throw guestError
            }
        } catch let guestError as FSProto.PosixError {
            throw guestError
        } catch let transport as FSTransportError {
            markDeadLocked()
            throw Self.mapTransport(transport)
        } catch {
            markDeadLocked()
            throw FSProto.PosixError(errno: EIO, message: "frame error")
        }
    }

    // MARK: - Typed wrappers

    func statfs() throws -> FSProto.Statfs {
        guard case .statfs(let value) = try roundTrip(.statfs) else { throw Self.wrongReply }
        return value
    }

    func lookup(parent: UInt64, name: String) throws -> FSProto.Attr {
        guard !name.isEmpty else { throw FSProto.PosixError(errno: EINVAL, message: "empty name") }
        guard case .attr(let attr) = try roundTrip(.lookup(parent: parent, name: name)) else {
            throw Self.wrongReply
        }
        return attr
    }

    func getattr(node: UInt64, wanted: UInt32) throws -> FSProto.Attr {
        assert(node != 0, "node id must be non-zero")
        guard case .attr(let attr) = try roundTrip(.getattr(node: node, wanted: wanted)) else {
            throw Self.wrongReply
        }
        return attr
    }

    /// The guest serves a directory in one reply (eof always set, cookie 0), so
    /// pagination is the volume's job; only the entry list is surfaced here.
    func readdirplus(node: UInt64, wanted: UInt32) throws -> [FSProto.DirEntry] {
        assert(node != 0, "node id must be non-zero")
        let request = FSProto.Request.readdirplus(
            node: node, cookie: 0, maxEntries: .max, wanted: wanted)
        guard case .readdirplus(_, _, let entries) = try roundTrip(request) else {
            throw Self.wrongReply
        }
        return entries
    }

    func open(node: UInt64) throws -> UInt64 {
        assert(node != 0, "node id must be non-zero")
        guard case .open(let handle) = try roundTrip(.open(node: node, mode: 0)) else {
            throw Self.wrongReply
        }
        return handle
    }

    func read(handle: UInt64, offset: UInt64, length: UInt32) throws -> (data: [UInt8], eof: Bool) {
        let request = FSProto.Request.read(handle: handle, offset: offset, length: length)
        guard case .read(let data, let eof) = try roundTrip(request) else { throw Self.wrongReply }
        assert(data.count <= FSProto.readReplyCap, "read data within cap")
        return (data, eof)
    }

    func closeFile(handle: UInt64) throws {
        guard case .empty = try roundTrip(.closeFile(handle: handle)) else { throw Self.wrongReply }
    }

    func readlink(node: UInt64) throws -> String {
        assert(node != 0, "node id must be non-zero")
        guard case .readlink(let target) = try roundTrip(.readlink(node: node)) else {
            throw Self.wrongReply
        }
        return target
    }

    func reclaim(node: UInt64) throws {
        assert(node != 0, "node id must be non-zero")
        guard case .empty = try roundTrip(.reclaim(node: node)) else { throw Self.wrongReply }
    }

    func sync() throws {
        guard case .empty = try roundTrip(.sync) else { throw Self.wrongReply }
    }
}

extension FSClient {
    func write(node: UInt64, offset: UInt64, data: [UInt8]) throws -> (
        count: UInt32, attr: FSProto.Attr
    ) {
        try Self.requireNode(node)
        guard data.count <= FSProto.writeRequestCap else {
            throw FSProto.PosixError(errno: EINVAL, message: "write too large")
        }
        guard
            case .write(let count, let attr) = try roundTrip(
                .write(node: node, offset: offset, data: data)
            )
        else { throw Self.wrongReply }
        return (count, attr)
    }

    func setattr(node: UInt64, setattr: FSProto.SetAttr) throws -> FSProto.Attr {
        try Self.requireNode(node)
        guard case .attr(let attr) = try roundTrip(.setattr(node: node, setattr: setattr)) else {
            throw Self.wrongReply
        }
        return attr
    }

    // swiftlint:disable:next function_parameter_count
    func create(
        parent: UInt64, name: String, itemType: FSProto.ItemType, mode: UInt32, uid: UInt32,
        gid: UInt32
    ) throws -> FSProto.Attr {
        try Self.requireNode(parent)
        try Self.requireName(name)
        let request = FSProto.Request.create(
            parent: parent, name: name, itemType: itemType, mode: mode, uid: uid, gid: gid)
        guard case .attr(let attr) = try roundTrip(request) else { throw Self.wrongReply }
        return attr
    }

    func symlink(
        parent: UInt64, name: String, target: String, uid: UInt32, gid: UInt32
    ) throws -> FSProto.Attr {
        try Self.requireNode(parent)
        try Self.requireName(name)
        guard !target.isEmpty else {
            throw FSProto.PosixError(errno: EINVAL, message: "empty symlink target")
        }
        let request = FSProto.Request.symlink(
            parent: parent, name: name, target: target, uid: uid, gid: gid)
        guard case .attr(let attr) = try roundTrip(request) else { throw Self.wrongReply }
        return attr
    }

    func link(node: UInt64, newParent: UInt64, newName: String) throws -> FSProto.Attr {
        try Self.requireNode(node)
        try Self.requireNode(newParent)
        try Self.requireName(newName)
        guard
            case .attr(let attr) = try roundTrip(
                .link(node: node, newParent: newParent, newName: newName)
            )
        else { throw Self.wrongReply }
        return attr
    }

    func remove(parent: UInt64, name: String, itemType: FSProto.ItemType) throws {
        try Self.requireNode(parent)
        try Self.requireName(name)
        guard case .empty = try roundTrip(.remove(parent: parent, name: name, itemType: itemType))
        else { throw Self.wrongReply }
    }

    // swiftlint:disable:next function_parameter_count
    func rename(
        node: UInt64, srcParent: UInt64, srcName: String, dstParent: UInt64, dstName: String,
        replace: Bool
    ) throws -> FSProto.Attr {
        try Self.requireNode(node)
        try Self.requireNode(srcParent)
        try Self.requireNode(dstParent)
        try Self.requireName(srcName)
        try Self.requireName(dstName)
        let flags: UInt8 = replace ? 1 : 0
        guard
            case .attr(let attr) = try roundTrip(
                .rename(
                    node: node, srcParent: srcParent, srcName: srcName, dstParent: dstParent,
                    dstName: dstName, flags: flags)
            )
        else { throw Self.wrongReply }
        return attr
    }
}

extension FSClient {
    // MARK: - Internals

    private static let wrongReply = FSProto.PosixError(errno: EIO, message: "unexpected reply body")

    private func handshake(distro: String, mountID: String, nonce: String, readonly: Bool) throws {
        assert(fd >= 0, "handshake needs a connected fd")
        assert(!distro.isEmpty, "distro validated before handshake")
        do {
            let hello = FSHello(
                distro: distro, mountID: mountID, nonce: nonce, readonly: readonly)
            try FSFrame.writeFrame(fd, [UInt8](hello.encoded()))
            let reply = try FSControlReply.decode(Data(FSFrame.readFrame(fd)))
            guard reply.ok else {
                markDeadLocked()
                throw FSProto.PosixError(errno: ENODEV, message: reply.error ?? "mount refused")
            }
        } catch let posix as FSProto.PosixError {
            markDeadLocked()
            throw posix
        } catch {
            markDeadLocked()
            throw FSProto.PosixError(errno: ENODEV, message: "handshake failed")
        }
    }

    private func markDeadLocked() {
        dead = true
        if fd >= 0 {
            _ = Darwin.close(fd)
            fd = -1
        }
    }

    private static func mapTransport(_ error: FSTransportError) -> FSProto.PosixError {
        switch error {
        case .peerClosed: return FSProto.PosixError(errno: ENODEV, message: "peer closed")
        case .timedOut: return FSProto.PosixError(errno: ETIMEDOUT, message: "op timed out")
        case .oversize(let size): return FSProto.PosixError(errno: EIO, message: "oversize \(size)")
        case .io(let code): return FSProto.PosixError(errno: code == 0 ? EIO : code, message: "io")
        }
    }

    private static func socketPath() -> String? {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FSProto.appGroupID)
        guard let container = base else { return nil }
        let sock = container.appendingPathComponent(FSProto.appexSocketName)
        assert(sock.isFileURL, "container URL must be a file URL")
        return sock.path
    }

    private static func requireNode(_ node: UInt64) throws {
        guard node != 0 else {
            throw FSProto.PosixError(errno: EINVAL, message: "zero node id")
        }
    }

    private static func requireName(_ name: String) throws {
        guard !name.isEmpty else {
            throw FSProto.PosixError(errno: EINVAL, message: "empty name")
        }
    }

    /// The per-op deadline is a reliability guarantee, so a failed install fails
    /// the connect rather than leaving a socket that could block a Finder op.
    private static func applyTimeout(_ fd: Int32, _ option: Int32, _ seconds: Double) -> Bool {
        assert(fd >= 0, "timeout fd must be valid")
        assert(seconds > 0, "timeout must be positive")
        let whole = seconds.rounded(.down)
        var tv = timeval(
            tv_sec: Int(whole), tv_usec: suseconds_t((seconds - whole) * 1_000_000))
        return setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    /// Disable SIGPIPE so peer-close writes report `EPIPE` through `roundTrip`
    /// instead of terminating the appex process.
    private static func setNoSigPipe(_ fd: Int32) -> Bool {
        assert(fd >= 0, "fd must be valid")
        var one: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            == 0
    }

    private static func connectUDS(_ fd: Int32, path: String) -> Bool {
        assert(fd >= 0, "connect fd must be valid")
        assert(!path.isEmpty, "socket path must not be empty")
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for idx in 0..<bytes.count { dst[idx] = CChar(bitPattern: bytes[idx]) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        return rc == 0
    }
}
