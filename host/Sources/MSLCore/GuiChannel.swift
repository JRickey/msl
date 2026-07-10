import Darwin
import Foundation

/// Monotonic host clock in nanoseconds (mach_absolute_time-derived), used for
/// every present_ack and input timestamp so latencies are drift-free.
public enum GuiClock {
    public static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Blocking reads belong on the presenter reader thread; sends use a serial
/// queue so caller threads never wait on vsock backpressure.
public final class GuiChannel: @unchecked Sendable {
    private var fd: Int32
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "msl.gui.write", qos: .userInitiated)
    // A hard cap prevents peer backpressure from growing memory without bound.
    private let writeSlots = DispatchSemaphore(value: 64)
    private let beforeWrite: (@Sendable () -> Void)?
    private let afterReadLease: (@Sendable () -> Void)?
    private var onStall: (@Sendable () -> Void)?
    // Saturation marks the channel dead before notification; shutdown waits for the handler.
    private var didSignalStall = false
    private var dead = false
    private var stallShutdownPending = false
    private var shutdownStarted = false
    // The descriptor stays owned until every I/O lease releases, preventing fd-reuse races.
    private var leaseCount = 0

    public convenience init(fd: Int32) throws {
        try self.init(fd: fd, beforeWrite: nil, afterReadLease: nil)
    }

    init(
        fd: Int32, beforeWrite: (@Sendable () -> Void)?,
        afterReadLease: (@Sendable () -> Void)? = nil
    ) throws {
        guard fd >= 0 else { throw MSLError.io("gui channel fd invalid (\(fd))") }
        self.fd = fd
        self.beforeWrite = beforeWrite
        self.afterReadLease = afterReadLease
        try Self.setBlocking(fd)
        try Self.setNoSigPipe(fd)
    }

    /// The callback runs at most once and before saturation-triggered socket shutdown.
    public func setStallHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        onStall = handler
    }

    public func close() {
        let handle: Int32? = withLock {
            assertStateLocked()
            dead = true
            guard !stallShutdownPending, !shutdownStarted else { return nil }
            return prepareShutdownLocked()
        }
        if let handle { shutdownLeasedFD(handle) }
    }

    public func readFrame() throws -> GuiInboundFrame {
        let headerBytes = try readExactly(GuiProto.headerSize)
        let parsed = try GuiProto.parseHeader(Data(headerBytes))
        assert(headerBytes.count == GuiProto.headerSize, "GUI frame header must be complete")
        assert(parsed.type != 0, "GUI frame type zero is reserved")
        let payload = parsed.len > 0 ? Data(try readExactly(parsed.len)) : Data()
        return GuiInboundFrame(type: parsed.type, flags: parsed.flags, payload: payload)
    }

    /// Never waits for queue capacity; saturation marks the channel dead asynchronously.
    public func send(type: UInt32, flags: UInt32, payload: Data) {
        assert(payload.count <= GuiProto.maxFrame, "send payload must fit the frame bound")
        assert(type != 0, "GUI frame type zero is reserved")
        guard isOpen() else { return }
        guard writeSlots.wait(timeout: .now()) == .success else {
            signalStall()
            return
        }
        guard isOpen() else {
            writeSlots.signal()
            return
        }
        writeQueue.async { [weak self, writeSlots] in
            defer { writeSlots.signal() }
            self?.beforeWrite?()
            self?.writeFrame(type: type, flags: flags, payload: payload)
        }
    }

    private func signalStall() {
        let notification: StallNotification? = withLock {
            assertStateLocked()
            guard !didSignalStall, !dead else { return nil }
            didSignalStall = true
            dead = true
            stallShutdownPending = true
            assertStateLocked()
            return StallNotification(handler: onStall)
        }
        guard let notification else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            notification.handler?()
            finishStallShutdown()
        }
    }

    private func finishStallShutdown() {
        let handle: Int32? = withLock {
            assert(stallShutdownPending, "stall shutdown must be pending")
            assert(dead, "stall shutdown requires a dead channel")
            stallShutdownPending = false
            guard !shutdownStarted else { return nil }
            return prepareShutdownLocked()
        }
        if let handle { shutdownLeasedFD(handle) }
    }

    private func isOpen() -> Bool {
        withLock {
            assertStateLocked()
            return !dead
        }
    }

    private func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func writeFrame(type: UInt32, flags: UInt32, payload: Data) {
        assert(type != 0, "GUI frame type zero is reserved")
        assert(payload.count <= GuiProto.maxFrame, "GUI frame payload must fit the bound")
        guard
            let header = try? GuiProto.header(
                type: type, flags: flags, payloadLen: payload.count)
        else {
            close()
            return
        }
        assert(header.count == GuiProto.headerSize, "GUI frame header must be complete")
        do {
            try writeAll([UInt8](header))
            if !payload.isEmpty { try writeAll([UInt8](payload)) }
        } catch {
            close()
        }
    }

    private func acquireFD() throws -> Int32 {
        try withLock {
            assertStateLocked()
            guard !dead, fd >= 0 else { throw MSLError.io("gui channel closed") }
            leaseCount += 1
            assert(leaseCount > 0, "GUI descriptor lease count must be positive")
            assertStateLocked()
            return fd
        }
    }

    private func releaseFD() {
        let handle: Int32? = withLock {
            precondition(leaseCount > 0, "GUI descriptor lease release must be balanced")
            assert(fd >= 0, "an active GUI descriptor lease owns a descriptor")
            guard dead, shutdownStarted, leaseCount == 1 else {
                leaseCount -= 1
                assertStateLocked()
                return nil
            }
            return fd
        }
        guard let handle else { return }
        let result = Darwin.close(handle)
        precondition(result == 0, "GUI descriptor close failed with errno \(errno)")
        withLock {
            precondition(leaseCount == 1, "GUI close must hold the final descriptor lease")
            assert(fd == handle, "GUI close must finalize the leased descriptor")
            leaseCount = 0
            fd = -1
            assertStateLocked()
        }
    }

    private func prepareShutdownLocked() -> Int32 {
        precondition(dead && !shutdownStarted, "GUI shutdown preparation requires a dead channel")
        assert(fd >= 0, "GUI shutdown requires an owned descriptor")
        shutdownStarted = true
        leaseCount += 1
        assertStateLocked()
        return fd
    }

    private func shutdownLeasedFD(_ handle: Int32) {
        withLock {
            assert(handle == fd, "GUI shutdown must use the leased descriptor")
            assert(dead && shutdownStarted, "GUI shutdown lease requires shutdown state")
        }
        let result = Darwin.shutdown(handle, SHUT_RDWR)
        precondition(
            result == 0 || errno == ENOTCONN, "GUI descriptor shutdown failed with errno \(errno)")
        releaseFD()
    }

    private func assertStateLocked() {
        assert(leaseCount >= 0, "GUI descriptor lease count cannot be negative")
        assert(!stallShutdownPending || (dead && didSignalStall), "invalid stall shutdown state")
        assert(!shutdownStarted || dead, "GUI shutdown requires a dead channel")
        assert(fd >= 0 || (dead && shutdownStarted && leaseCount == 0), "invalid GUI fd state")
        assert(leaseCount == 0 || fd >= 0, "GUI descriptor leases require an owned descriptor")
    }

    private static func setBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw MSLError.io("fcntl F_GETFL failed: \(errno)") }
        guard fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            throw MSLError.io("fcntl F_SETFL failed: \(errno)")
        }
    }

    private static func setNoSigPipe(_ fd: Int32) throws {
        var enabled: Int32 = 1
        let result = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        guard result == 0 else {
            throw MSLError.io("setsockopt SO_NOSIGPIPE failed: \(errno)")
        }
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        precondition(!bytes.isEmpty, "writeAll needs a non-empty buffer")
        let handle = try acquireFD()
        defer { releaseFD() }
        assert(bytes.count <= GuiProto.maxFrame, "GUI write must fit the frame bound")
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
        if count == 0 { return [] }
        let handle = try acquireFD()
        defer { releaseFD() }
        afterReadLease?()
        assert(count > 0, "leased GUI reads must request bytes")
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

    private struct StallNotification: Sendable {
        let handler: (@Sendable () -> Void)?
    }
}
