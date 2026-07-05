import Darwin
import Foundation

/// Daemon-side of the Unit 0 spike: a small `AF_UNIX` `SOCK_STREAM` server that
/// accepts the FSKit appex, reads kernel-attested peer credentials and the
/// audit token, checks the pinned designated requirement, and echoes `ok`.
struct ProbeServer {
    let socketPath: String
    let once: Bool
    let requirement: String

    /// Bind, then serve until `once` is satisfied. Throws on bind failure so the
    /// caller can exit non-zero; per-connection errors are logged, not fatal.
    func run() throws {
        precondition(!socketPath.isEmpty, "socket path must not be empty")
        precondition(!requirement.isEmpty, "requirement must not be empty")
        let listener = try bind()
        defer {
            _ = Darwin.close(listener)
            _ = Darwin.unlink(socketPath)
        }
        FileHandle.standardError.write(Data("probe-server: listening at \(socketPath)\n".utf8))
        for _ in 0..<1024 {  // bounded: `once` returns after the first client
            let fd = accept(listener)
            guard fd >= 0 else { continue }
            serve(fd)
            _ = Darwin.close(fd)
            if once { return }
        }
    }

    private func bind() throws -> Int32 {
        assert(!socketPath.isEmpty, "socket path validated by run()")
        if Darwin.access(socketPath, F_OK) == 0 { _ = Darwin.unlink(socketPath) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProbeError.syscall("socket", errno) }
        var addr = sockaddr_un()
        guard fillSockaddr(&addr, path: socketPath) else {
            _ = Darwin.close(fd)
            throw ProbeError.pathTooLong(socketPath)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard rc == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            throw ProbeError.syscall("bind", err)
        }
        guard Darwin.chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            throw ProbeError.syscall("listen", err)
        }
        return fd
    }

    private func accept(_ listener: Int32) -> Int32 {
        assert(listener >= 0, "listener fd must be valid")
        for _ in 0..<64 {  // bounded: only EINTR loops
            let fd = Darwin.accept(listener, nil, nil)
            if fd >= 0 { return fd }
            if errno == EINTR { continue }
            FileHandle.standardError.write(Data("probe-server: accept errno=\(errno)\n".utf8))
            return -1
        }
        return -1
    }

    private func serve(_ fd: Int32) {
        assert(fd >= 0, "connection fd must be valid")
        guard let peer = PeerAuth.identity(fd: fd) else {
            report("peer credential read failed errno=\(errno)")
            return
        }
        let status = PeerAuth.validate(auditToken: peer.auditToken, requirement: requirement)
        let verdict = status == errSecSuccess ? "PASS" : "FAIL(\(status))"
        report(
            "peer euid=\(peer.euid) epid=\(peer.epid) token=\(hex(peer.auditToken)) dr=\(verdict)")
        let line = readLine(fd)
        report("probe message: \(line)")
        _ = writeAll(fd, Data("ok\n".utf8))
    }

    private func report(_ message: String) {
        precondition(!message.isEmpty, "log message must not be empty")
        FileHandle.standardOutput.write(Data("probe-server: \(message)\n".utf8))
    }

    private func hex(_ data: Data) -> String {
        assert(!data.isEmpty, "token must not be empty")
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private func readLine(_ fd: Int32) -> String {
        assert(fd >= 0, "fd must be valid")
        var out = [UInt8]()
        var byte: UInt8 = 0
        for _ in 0..<8192 {  // bounded: a probe line is short
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { break }
                out.append(byte)
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        assert(fd >= 0, "fd must be valid")
        let bytes = [UInt8](data)
        var sent = 0
        for _ in 0..<(bytes.count + 8) {  // bounded: each write advances >=1 byte
            if sent == bytes.count { return true }
            let count = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if count > 0 {
                sent += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return false
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case syscall(String, Int32)
    case pathTooLong(String)

    var description: String {
        switch self {
        case .syscall(let name, let err): return "\(name) failed: errno=\(err)"
        case .pathTooLong(let path): return "socket path too long: \(path)"
        }
    }
}

/// Populate `sockaddr_un`; returns false if the path exceeds the 104-byte field.
func fillSockaddr(_ addr: inout sockaddr_un, path: String) -> Bool {
    precondition(!path.isEmpty, "path must not be empty")
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
    return true
}
