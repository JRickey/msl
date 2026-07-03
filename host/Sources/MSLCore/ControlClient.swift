import Foundation

/// Serializes every control-channel (5000) request behind one lock so that
/// requests originating on different threads — a SIGWINCH resize, a wake-driven
/// set_time, the attach flow's session_open/wait — never interleave frames.
public final class ControlClient: @unchecked Sendable {
    private let client: VsockClient
    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private let baseReceiveTimeout: Double

    /// Bounds every control round-trip with a receive timeout so a wedged agent
    /// can never leave a caller (e.g. SessionAttach's teardown) blocked forever.
    public init(client: VsockClient, receiveTimeout: Double = 10) throws {
        precondition(receiveTimeout > 0, "control receive timeout must be positive")
        self.client = client
        self.baseReceiveTimeout = receiveTimeout
        try client.setReceiveTimeout(seconds: receiveTimeout)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        client.close()
    }

    public func ping() throws -> PingData {
        return try roundTrip { id in try Request.ping(id: id).encoded() }
    }

    public func distroUp(dev: String, hostname: String, macShare: Bool) throws -> DistroData {
        precondition(!dev.isEmpty, "distro dev must not be empty")
        let req = DistroUpReq(dev: dev, hostname: hostname, macShare: macShare)
        return try roundTrip(makeOp("distro_up", req))
    }

    public func distroState() throws -> DistroData {
        return try roundTrip(makeOp("distro_state", Optional<EmptyReq>.none))
    }

    public func sessionOpen(_ req: SessionOpenReq) throws -> SessionOpenData {
        precondition(!req.argv.isEmpty, "session argv must not be empty")
        return try roundTrip(makeOp("session_open", req))
    }

    public func sessionResize(sessionID: UInt64, rows: UInt16, cols: UInt16) throws {
        let req = SessionResizeReq(sessionID: sessionID, rows: rows, cols: cols)
        let _: EmptyData = try roundTrip(makeOp("session_resize", req))
    }

    public func sessionSignal(sessionID: UInt64, signal: Int32) throws {
        let req = SessionSignalReq(sessionID: sessionID, signal: signal)
        let _: EmptyData = try roundTrip(makeOp("session_signal", req))
    }

    public func sessionWait(sessionID: UInt64) throws -> SessionWaitData {
        let req = SessionWaitReq(sessionID: sessionID)
        return try roundTrip(makeOp("session_wait", req))
    }

    public func setTime(sec: Int64, usec: Int64) throws {
        let req = SetTimeReq(sec: sec, usec: usec)
        let _: EmptyData = try roundTrip(makeOp("set_time", req))
    }

    /// Graceful distro shutdown (v1.1). The guest worst case is timeout_ms +
    /// 2s kill-grace + an unbounded sync/unmount, so the v1.1.1 timing contract
    /// requires a receive timeout of at least timeout_ms + 15s (sync budget)
    /// before the host may power-yank; raise it for this call, then restore.
    public func distroDown(timeoutMs: UInt64) throws -> DistroData {
        precondition(timeoutMs > 0, "distro_down timeout must be positive")
        let receiveTimeout = Double(timeoutMs) / 1000.0 + 15
        let req = DistroDownReq(timeoutMs: timeoutMs)
        return try roundTrip(receiveTimeout: receiveTimeout, makeOp("distro_down", req))
    }

    /// Encode + send + receive + decode under the lock; `id` is assigned here so
    /// every in-flight request carries a unique, monotonically increasing id.
    private func roundTrip<Payload: Decodable & Sendable>(
        _ encode: @Sendable (UInt64) throws -> Data
    ) throws -> Payload {
        lock.lock()
        defer { lock.unlock() }
        return try sendReceive(encode)
    }

    /// Round-trip with a one-shot receive timeout (for ops that can legitimately
    /// take longer than the base timeout); restores the base timeout after.
    private func roundTrip<Payload: Decodable & Sendable>(
        receiveTimeout: Double, _ encode: @Sendable (UInt64) throws -> Data
    ) throws -> Payload {
        precondition(receiveTimeout > 0, "receive timeout must be positive")
        lock.lock()
        defer { lock.unlock() }
        try client.setReceiveTimeout(seconds: receiveTimeout)
        defer { try? client.setReceiveTimeout(seconds: baseReceiveTimeout) }
        return try sendReceive(encode)
    }

    /// Send/receive/decode one framed request; caller must hold `lock`.
    private func sendReceive<Payload: Decodable & Sendable>(
        _ encode: @Sendable (UInt64) throws -> Data
    ) throws -> Payload {
        let id = nextID
        nextID &+= 1
        let payload = try encode(id)
        try client.send(payload)
        let reply = try client.receive()
        let response = try Response<Payload>.decode(reply, expectedID: id)
        guard response.ok, let data = response.data else {
            throw MSLError.protocolMismatch(response.error ?? "control request failed")
        }
        return data
    }

    private func makeOp<Req: Encodable & Sendable>(
        _ op: String, _ req: Req?
    ) -> @Sendable (UInt64) throws -> Data {
        return { id in try OpRequest(id: id, op: op, req: req).encoded() }
    }
}

/// Placeholder `req` type for ops that carry no body (`distro_state`).
public struct EmptyReq: Encodable, Sendable {}
