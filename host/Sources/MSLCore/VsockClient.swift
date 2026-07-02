import Darwin
import Foundation

/// Length-prefixed JSON frame client over a vsock file descriptor. Owns the
/// descriptor and closes it on `close()`. All calls are synchronous and are
/// expected to run off the VM's serial queue (see `Driver`).
public final class VsockClient: @unchecked Sendable {
    private var fd: Int32
    private let headerSize = 4

    /// Takes ownership of an already-duplicated blocking-capable descriptor.
    public init(fileDescriptor: Int32) throws {
        guard fileDescriptor >= 0 else {
            throw MSLError.io("vsock descriptor is invalid (\(fileDescriptor))")
        }
        self.fd = fileDescriptor
        try Self.setBlocking(fileDescriptor)
    }

    deinit {
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    public func close() {
        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
        fd = -1
    }

    /// Set a receive timeout so a `receive()` cannot block forever; `receive`
    /// throws `MSLError.timedOut` when it fires. Zero means block indefinitely.
    public func setReceiveTimeout(seconds: Double) throws {
        guard fd >= 0 else { throw MSLError.io("set timeout on closed vsock") }
        precondition(seconds >= 0, "receive timeout must be non-negative")
        let whole = seconds.rounded(.down)
        var tv = timeval(
            tv_sec: __darwin_time_t(whole),
            tv_usec: suseconds_t((seconds - whole) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size) == 0 else {
            throw MSLError.io("setsockopt SO_RCVTIMEO failed: errno=\(errno)")
        }
    }

    /// Relinquish ownership of the descriptor without closing it; the caller
    /// takes over (used to switch the data plane to raw byte streaming). Any
    /// receive timeout is cleared so raw pump reads on the fd never time out.
    public func detachDescriptor() -> Int32 {
        let owned = fd
        if owned >= 0 {
            var tv = timeval(tv_sec: 0, tv_usec: 0)
            _ = setsockopt(
                owned, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        fd = -1
        return owned
    }

    /// Send one frame: 4-byte big-endian length header, then the payload.
    public func send(_ payload: Data) throws {
        guard fd >= 0 else { throw MSLError.io("send on closed vsock") }
        guard payload.count <= Proto.maxPayload else {
            throw MSLError.framing("outgoing frame \(payload.count) exceeds \(Proto.maxPayload)")
        }
        let length = UInt32(payload.count)
        var header = [UInt8](repeating: 0, count: headerSize)
        header[0] = UInt8((length >> 24) & 0xff)
        header[1] = UInt8((length >> 16) & 0xff)
        header[2] = UInt8((length >> 8) & 0xff)
        header[3] = UInt8(length & 0xff)
        try writeAll(header)
        try writeAll([UInt8](payload))
    }

    /// Receive one frame, enforcing the 4 MiB bound before allocating the body.
    public func receive() throws -> Data {
        guard fd >= 0 else { throw MSLError.io("receive on closed vsock") }
        let header = try readExactly(headerSize)
        assert(header.count == headerSize, "readExactly must return the requested count")
        let length =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8)
            | Int(header[3])
        guard length >= 0 else { throw MSLError.framing("negative frame length") }
        guard length <= Proto.maxPayload else {
            throw MSLError.framing("incoming frame \(length) exceeds \(Proto.maxPayload)")
        }
        let body = try readExactly(length)
        return Data(body)
    }

    private static func setBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw MSLError.io("fcntl F_GETFL failed: \(errno)") }
        let result = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        guard result >= 0 else { throw MSLError.io("fcntl F_SETFL failed: \(errno)") }
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        guard fd >= 0 else { throw MSLError.io("write on closed vsock") }
        var sent = 0
        let cap = bytes.count + 64  // bounded: each write advances >=1 byte
        for _ in 0..<cap {
            if sent == bytes.count { return }
            let chunk = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return Int.min }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if chunk > 0 {
                sent += chunk
            } else if chunk < 0 && chunk != Int.min && errno == EINTR {
                continue
            } else {
                throw MSLError.io("write returned \(chunk) errno=\(errno)")
            }
        }
        throw MSLError.io("write did not complete within bound")
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw MSLError.framing("negative read count") }
        guard fd >= 0 else { throw MSLError.io("read on closed vsock") }
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        let cap = count + 64  // bounded: each read advances >=1 byte
        for _ in 0..<cap {
            if got == count { return buffer }
            let chunk = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return Int.min }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if chunk > 0 {
                got += chunk
            } else if chunk == 0 {
                throw MSLError.io("vsock closed mid-frame after \(got)/\(count) bytes")
            } else if chunk != Int.min && errno == EINTR {
                continue
            } else if chunk != Int.min && (errno == EAGAIN || errno == EWOULDBLOCK) {
                throw MSLError.timedOut("receive after \(got)/\(count) bytes")
            } else {
                throw MSLError.io("read errno=\(errno)")
            }
        }
        throw MSLError.io("read did not complete within bound")
    }
}
