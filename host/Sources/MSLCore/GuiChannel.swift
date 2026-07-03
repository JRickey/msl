import Darwin
import Foundation

/// Monotonic host clock in nanoseconds (mach_absolute_time-derived), used for
/// every present_ack and input timestamp so latencies are drift-free.
public enum GuiClock {
    public static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Owns the raw byte pipe to the guest compositor and speaks GUI frames over it.
/// Blocking `readFrame` runs on the presenter's reader thread; `send` never
/// blocks the caller — it hands the frame to a serial writer queue so the main
/// thread is never stalled on vsock backpressure.
public final class GuiChannel: @unchecked Sendable {
    private var fd: Int32
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "msl.gui.write", qos: .userInitiated)
    // Bounds outstanding un-written frames: a bounded enqueue is an honest
    // backpressure proxy at spike grade. A full queue past `stallTimeoutMs`
    // means the peer/link is wedged, so we tear the channel down rather than
    // grow memory without limit.
    private let writeSlots = DispatchSemaphore(value: 64)
    private var onStall: (@Sendable () -> Void)?
    private static let stallTimeoutMs = 250

    public init(fd: Int32) throws {
        guard fd >= 0 else { throw MSLError.io("gui channel fd invalid (\(fd))") }
        self.fd = fd
        try Self.setBlocking(fd)
    }

    /// Register the callback fired when the writer backlog signals a wedged peer;
    /// the presenter uses it to finalize the spike with a clear error.
    public func setStallHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        onStall = handler
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            _ = Darwin.close(fd)
            fd = -1
        }
    }

    /// Read one full frame (16-byte header then payload). Throws on EOF/error so
    /// the reader loop can terminate the presenter cleanly.
    public func readFrame() throws -> GuiInboundFrame {
        let headerBytes = try readExactly(GuiProto.headerSize)
        let parsed = try GuiProto.parseHeader(Data(headerBytes))
        assert(parsed.len >= 0, "parsed frame length is non-negative")
        let payload = parsed.len > 0 ? Data(try readExactly(parsed.len)) : Data()
        return GuiInboundFrame(type: parsed.type, flags: parsed.flags, payload: payload)
    }

    /// Enqueue a frame for transmission; returns immediately in the common case.
    /// If the writer backlog is full past the stall timeout, the peer/link is
    /// wedged: close and signal the stall instead of queueing without bound.
    public func send(type: UInt32, flags: UInt32, payload: Data) {
        assert(payload.count <= GuiProto.maxFrame, "send payload must fit the frame bound")
        let deadline = DispatchTime.now() + .milliseconds(Self.stallTimeoutMs)
        guard writeSlots.wait(timeout: deadline) == .success else {
            close()
            let handler = withLock { onStall }
            handler?()
            return
        }
        writeQueue.async { [weak self, writeSlots] in
            defer { writeSlots.signal() }
            self?.writeFrame(type: type, flags: flags, payload: payload)
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func writeFrame(type: UInt32, flags: UInt32, payload: Data) {
        guard
            let header = try? GuiProto.header(
                type: type, flags: flags, payloadLen: payload.count)
        else {
            close()
            return
        }
        do {
            try writeAll([UInt8](header))
            if !payload.isEmpty { try writeAll([UInt8](payload)) }
        } catch {
            close()
        }
    }

    private func currentFD() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw MSLError.io("gui channel closed") }
        return fd
    }

    private static func setBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw MSLError.io("fcntl F_GETFL failed: \(errno)") }
        guard fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            throw MSLError.io("fcntl F_SETFL failed: \(errno)")
        }
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        precondition(!bytes.isEmpty, "writeAll needs a non-empty buffer")
        let handle = try currentFD()
        var sent = 0
        let cap = bytes.count + 64  // bounded: each write advances ≥1 byte
        for _ in 0..<cap {
            if sent == bytes.count { return }
            let chunk = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return Int.min }
                return Darwin.write(handle, base.advanced(by: sent), bytes.count - sent)
            }
            if chunk > 0 {
                sent += chunk
            } else if chunk < 0 && chunk != Int.min && errno == EINTR {
                continue
            } else {
                throw MSLError.io("gui write returned \(chunk) errno=\(errno)")
            }
        }
        throw MSLError.io("gui write did not complete within bound")
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw MSLError.framing("gui read negative count") }
        guard count <= GuiProto.maxFrame else {
            throw MSLError.framing("gui read \(count) exceeds \(GuiProto.maxFrame)")
        }
        let handle = try currentFD()
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        let cap = count + 64  // bounded: each read advances ≥1 byte
        for _ in 0..<cap {
            if got == count { return buffer }
            let chunk = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return Int.min }
                return Darwin.read(handle, base.advanced(by: got), count - got)
            }
            if chunk > 0 {
                got += chunk
            } else if chunk == 0 {
                throw MSLError.io("gui channel closed mid-frame after \(got)/\(count)")
            } else if chunk != Int.min && errno == EINTR {
                continue
            } else {
                throw MSLError.io("gui read errno=\(errno)")
            }
        }
        throw MSLError.io("gui read did not complete within bound")
    }
}
