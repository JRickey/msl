import Darwin
import Foundation

public struct HostSSHAgentProxy: Sendable {
    public static let maxPacket = 1024 * 1024

    private let socketPath: String?
    private let dial: (@Sendable (String) throws -> Int32)?

    public init(
        socketPath: String? = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
        dial: (@Sendable (String) throws -> Int32)? = nil
    ) {
        self.socketPath = socketPath
        self.dial = dial
    }

    public var available: Bool {
        guard let socketPath, !socketPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    public func forward(packet: Data) throws -> Data {
        guard !packet.isEmpty else { throw AuthProxyError.badRequest("empty ssh-agent packet") }
        guard packet.count <= Self.maxPacket else { throw AuthProxyError.tooLarge }
        try Self.validateAllowed(packet)
        guard let socketPath, !socketPath.isEmpty else { throw AuthProxyError.unavailable }
        let fd = try (dial ?? Self.defaultDial)(socketPath)
        defer { _ = Darwin.close(fd) }
        try writeFrame(packet, fd: fd)
        return try readFrame(fd: fd)
    }

    static func validateAllowed(_ packet: Data) throws {
        guard let type = packet.first else { throw AuthProxyError.badRequest("missing type") }
        switch type {
        case 11, 13, 27:
            return
        default:
            throw AuthProxyError.denied("ssh-agent request \(type) is not forwarded")
        }
    }

    private static func defaultDial(_ path: String) throws -> Int32 {
        return try LocalSocket.dial(path: path)
    }

    private func writeFrame(_ packet: Data, fd: Int32) throws {
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
        let header = try readExactly(4, fd: fd)
        let length =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8)
            | Int(header[3])
        guard (0...Self.maxPacket).contains(length) else { throw AuthProxyError.tooLarge }
        return Data(try readExactly(length, fd: fd))
    }

    private func writeAll(_ bytes: [UInt8], fd: Int32) throws {
        var sent = 0
        for _ in 0..<(bytes.count + 64) {
            if sent == bytes.count { return }
            let chunk = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return Int.min }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if chunk > 0 {
                sent += chunk
            } else if chunk != Int.min && errno == EINTR {
                continue
            } else {
                throw AuthProxyError.io("ssh-agent write errno=\(errno)")
            }
        }
        throw AuthProxyError.io("ssh-agent write did not complete")
    }

    private func readExactly(_ count: Int, fd: Int32) throws -> [UInt8] {
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        for _ in 0..<(count + 64) {
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
            } else {
                throw AuthProxyError.io("ssh-agent read errno=\(errno)")
            }
        }
        throw AuthProxyError.io("ssh-agent read did not complete")
    }
}

public enum AuthProxyError: Error, Equatable {
    case badRequest(String)
    case denied(String)
    case unavailable
    case tooLarge
    case io(String)
}
