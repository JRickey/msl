import Darwin
import Foundation
import MSLFSWire

/// Transport failure on the spliced fs channel, distinct from a guest-side
/// `FSProto.PosixError`: any of these means the mount is dead.
enum FSTransportError: Error, Equatable {
    case peerClosed
    case oversize(Int)
    case io(Int32)
    case timedOut
}

/// 4-byte big-endian length prefix then the payload, byte-identical to
/// `msl-wire::frame` (the daemon splices raw, so the encoding must match). The
/// bound is `FSProto.frameMax`; a zero-length read means the peer closed.
enum FSFrame {
    static let maxFrame = FSProto.frameMax

    static func writeFrame(_ fd: Int32, _ payload: [UInt8]) throws {
        assert(fd >= 0, "write fd must be valid")
        guard fd >= 0 else { throw FSTransportError.io(EBADF) }
        guard payload.count <= maxFrame else { throw FSTransportError.oversize(payload.count) }
        let length = UInt32(payload.count)
        var header = [UInt8](repeating: 0, count: 4)
        header[0] = UInt8((length >> 24) & 0xff)
        header[1] = UInt8((length >> 16) & 0xff)
        header[2] = UInt8((length >> 8) & 0xff)
        header[3] = UInt8(length & 0xff)
        try writeAll(fd, header)
        try writeAll(fd, payload)
    }

    static func readFrame(_ fd: Int32) throws -> [UInt8] {
        assert(fd >= 0, "read fd must be valid")
        guard fd >= 0 else { throw FSTransportError.io(EBADF) }
        let header = try readExactly(fd, 4)
        assert(header.count == 4, "readExactly returns the requested count")
        let length =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        guard length >= 0, length <= maxFrame else { throw FSTransportError.oversize(length) }
        return try readExactly(fd, length)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        assert(fd >= 0, "write fd must be valid")
        guard !bytes.isEmpty else { return }
        var sent = 0
        let cap = bytes.count + 64  // bounded: each write advances >=1 byte
        for _ in 0..<cap {
            if sent == bytes.count { return }
            let count = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            let savedErrno = errno
            if count > 0 {
                sent += count
            } else if count < 0 && savedErrno == EINTR {
                continue
            } else {
                throw FSTransportError.io(savedErrno)
            }
        }
        throw FSTransportError.io(EIO)
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        assert(fd >= 0, "read fd must be valid")
        assert(count >= 0, "read count must be non-negative")
        guard count >= 0 else { throw FSTransportError.io(EINVAL) }
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        let cap = count + 64  // bounded: each read advances >=1 byte
        for _ in 0..<cap {
            if got == count { return buffer }
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return Int.min }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            let savedErrno = errno
            if read > 0 {
                got += read
            } else if read == 0 {
                throw FSTransportError.peerClosed
            } else if read != Int.min && savedErrno == EINTR {
                continue
            } else if read != Int.min && (savedErrno == EAGAIN || savedErrno == EWOULDBLOCK) {
                throw FSTransportError.timedOut
            } else {
                throw FSTransportError.io(savedErrno)
            }
        }
        throw FSTransportError.io(EIO)
    }
}
