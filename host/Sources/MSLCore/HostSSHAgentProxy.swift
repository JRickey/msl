import Darwin
import Foundation

public struct HostSSHAgentProxy: Sendable {
    public static let maxPacket = 1024 * 1024
    /// Bounds one request against a live-but-hung agent that never replies.
    public static let socketTimeout = 10.0
    static let sessionBind = "session-bind@openssh.com"
    private static let sessionBindBytes = Array(sessionBind.utf8)

    private let socketPath: String?
    private let timeout: Double
    private let dial: (@Sendable (String) throws -> Int32)?

    public init(
        socketPath: String? = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
        timeout: Double = HostSSHAgentProxy.socketTimeout,
        dial: (@Sendable (String) throws -> Int32)? = nil
    ) {
        precondition(timeout > 0, "ssh-agent timeout must be positive")
        self.socketPath = socketPath
        self.timeout = timeout
        self.dial = dial
    }

    public var available: Bool {
        guard let socketPath, !socketPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    /// `forwarding` is the session's resolved agent-forwarding policy; `false`
    /// rejects an OpenSSH session-bind that declares forwarding.
    public func forward(packet: Data, forwarding: Bool) throws -> Data {
        guard !packet.isEmpty else { throw AuthProxyError.badRequest("empty ssh-agent packet") }
        guard packet.count <= Self.maxPacket else { throw AuthProxyError.tooLarge }
        try Self.validateAllowed(packet, forwarding: forwarding)
        guard let socketPath, !socketPath.isEmpty else { throw AuthProxyError.unavailable }
        let fd = try (dial ?? Self.defaultDial)(socketPath)
        guard fd >= 0 else { throw AuthProxyError.unavailable }
        defer { _ = Darwin.close(fd) }
        try Self.setTimeouts(fd: fd, seconds: timeout)
        try writeFrame(packet, fd: fd)
        return try readFrame(fd: fd)
    }

    static func validateAllowed(_ packet: Data, forwarding: Bool) throws {
        guard let type = packet.first else { throw AuthProxyError.badRequest("missing type") }
        assert(!packet.isEmpty, "packet with a first byte is not empty")
        switch type {
        case 11, 13:
            return
        case 27:
            try validateExtension([UInt8](packet.dropFirst()), forwarding: forwarding)
        default:
            throw AuthProxyError.denied("ssh-agent request \(type) is not forwarded")
        }
    }

    /// Only `session-bind@openssh.com` is inspected: its trailing `is_forwarding`
    /// flag is the one forwarding signal the agent protocol makes visible.
    private static func validateExtension(_ body: [UInt8], forwarding: Bool) throws {
        guard let name = readString(body, at: 0) else {
            throw AuthProxyError.badRequest("bad ssh-agent extension name")
        }
        assert(name.next >= 4, "a parsed string consumes its 4-byte length prefix")
        guard name.value.elementsEqual(sessionBindBytes) else { return }
        guard let flag = sessionBindFlag(body, at: name.next) else {
            throw AuthProxyError.badRequest("bad session-bind extension")
        }
        guard !flag || forwarding else {
            throw AuthProxyError.denied("ssh-agent forwarding is disabled by policy")
        }
    }

    /// session-bind carries hostkey, session id, signature, then `is_forwarding`.
    private static func sessionBindFlag(_ body: [UInt8], at start: Int) -> Bool? {
        assert(start >= 0, "session-bind parse offset must be non-negative")
        var offset = start
        for _ in 0..<3 {  // bounded: three fixed string fields precede the flag
            guard let field = readString(body, at: offset) else { return nil }
            offset = field.next
        }
        guard offset < body.count else { return nil }
        return body[offset] != 0
    }

    private static func readString(
        _ body: [UInt8], at offset: Int
    ) -> (value: ArraySlice<UInt8>, next: Int)? {
        guard offset >= 0, offset &+ 4 <= body.count else { return nil }
        let length =
            (Int(body[offset]) << 24) | (Int(body[offset + 1]) << 16)
            | (Int(body[offset + 2]) << 8) | Int(body[offset + 3])
        let start = offset + 4
        guard length >= 0, start &+ length <= body.count else { return nil }
        return (body[start..<(start + length)], start + length)
    }

    private static func setTimeouts(fd: Int32, seconds: Double) throws {
        precondition(fd >= 0, "ssh-agent descriptor must be valid")
        precondition(seconds > 0, "ssh-agent timeout must be positive")
        let whole = seconds.rounded(.down)
        var tv = timeval(
            tv_sec: __darwin_time_t(whole),
            tv_usec: suseconds_t((seconds - whole) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {  // bounded: two options
            guard setsockopt(fd, SOL_SOCKET, option, &tv, size) == 0 else {
                throw AuthProxyError.io("ssh-agent setsockopt failed errno=\(errno)")
            }
        }
    }

    private static func defaultDial(_ path: String) throws -> Int32 {
        assert(!path.isEmpty, "ssh-agent socket path must not be empty")
        return try LocalSocket.dial(path: path)
    }

    private func writeFrame(_ packet: Data, fd: Int32) throws {
        assert(!packet.isEmpty, "callers reject empty packets")
        assert(fd >= 0, "ssh-agent descriptor must be valid")
        let len = UInt32(packet.count)
        var bytes = Data()
        bytes.append(UInt8((len >> 24) & 0xff))
        bytes.append(UInt8((len >> 16) & 0xff))
        bytes.append(UInt8((len >> 8) & 0xff))
        bytes.append(UInt8(len & 0xff))
        bytes.append(packet)
        try writeAll(Array(bytes), fd: fd)
    }

    private func readFrame(fd: Int32) throws -> Data {
        assert(fd >= 0, "ssh-agent descriptor must be valid")
        let header = try readExactly(4, fd: fd)
        assert(header.count == 4, "readExactly returns the requested count or throws")
        let length =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8)
            | Int(header[3])
        guard (0...Self.maxPacket).contains(length) else { throw AuthProxyError.tooLarge }
        return Data(try readExactly(length, fd: fd))
    }

    private func writeAll(_ bytes: [UInt8], fd: Int32) throws {
        assert(fd >= 0, "ssh-agent descriptor must be valid")
        assert(!bytes.isEmpty, "framed writes always carry a header")
        var sent = 0
        for _ in 0..<(bytes.count + 64) {  // bounded: each write advances >=1 byte
            if sent == bytes.count { return }
            let chunk = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return Int.min }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if chunk > 0 {
                sent += chunk
            } else if chunk != Int.min && errno == EINTR {
                continue
            } else if chunk != Int.min && Self.isTimeout(errno) {
                throw AuthProxyError.timedOut("ssh-agent write timed out")
            } else {
                throw AuthProxyError.io("ssh-agent write errno=\(errno)")
            }
        }
        throw AuthProxyError.io("ssh-agent write did not complete")
    }

    private func readExactly(_ count: Int, fd: Int32) throws -> [UInt8] {
        assert(count >= 0, "read count must be non-negative")
        assert(fd >= 0, "ssh-agent descriptor must be valid")
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        for _ in 0..<(count + 64) {  // bounded: each read advances >=1 byte
            if got == count { return buffer }
            let chunk = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return Int.min }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if chunk > 0 {
                got += chunk
            } else if chunk == 0 {
                throw AuthProxyError.io("ssh-agent closed mid-frame")
            } else if chunk != Int.min && errno == EINTR {
                continue
            } else if chunk != Int.min && Self.isTimeout(errno) {
                throw AuthProxyError.timedOut("ssh-agent read timed out")
            } else {
                throw AuthProxyError.io("ssh-agent read errno=\(errno)")
            }
        }
        throw AuthProxyError.io("ssh-agent read did not complete")
    }

    private static func isTimeout(_ code: Int32) -> Bool {
        return code == EAGAIN || code == EWOULDBLOCK
    }
}

public enum AuthProxyError: Error, Equatable {
    case badRequest(String)
    case denied(String)
    case notFound(String)
    case locked(String)
    case unavailable
    case tooLarge
    case timedOut(String)
    case io(String)
    case backend(String)
}
