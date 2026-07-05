import Foundation

/// Client end of the local control plane: framed request/reply over the daemon
/// unix socket, serialized behind one lock so a SIGWINCH resize and the final
/// wait never interleave frames (same discipline as `ControlClient`).
public final class LocalClient: @unchecked Sendable {
    private let framed: VsockClient
    private let lock = NSLock()

    private init(framed: VsockClient) {
        self.framed = framed
    }

    /// Dial the daemon socket and wrap it with a bounded receive timeout (a first
    /// `shell` may trigger a VM boot, so the timeout is generous).
    public static func connect(path: String, receiveTimeout: Double = 120) throws -> LocalClient {
        precondition(!path.isEmpty, "socket path must not be empty")
        precondition(receiveTimeout > 0, "receive timeout must be positive")
        let fd = try LocalSocket.dial(path: path)
        let framed = try VsockClient(fileDescriptor: fd)
        try framed.setReceiveTimeout(seconds: receiveTimeout)
        return LocalClient(framed: framed)
    }

    public func close() { framed.close() }

    public func status() throws -> StatusData {
        return try roundTrip(.status)
    }

    public func up(name: String?) throws {
        let _: LocalEmpty = try roundTrip(.up(name: name))
    }

    public func down(name: String?, all: Bool, timeoutMs: UInt64?) throws {
        let _: LocalEmpty = try roundTrip(.down(name: name, all: all, timeoutMs: timeoutMs))
    }

    public func shell(_ req: ShellRequest) throws -> ShellData {
        return try roundTrip(.shell(req))
    }

    public func shutdown() throws {
        let _: LocalEmpty = try roundTrip(.shutdown)
    }

    public func mountPrepare(name: String?) throws -> MountPrepareData {
        return try roundTrip(.mountPrepare(name: name))
    }

    public func mountCommit(name: String, mountpoint: String) throws {
        let _: LocalEmpty = try roundTrip(.mountCommit(name: name, mountpoint: mountpoint))
    }

    public func mountUnmount(name: String, force: Bool) throws {
        let _: LocalEmpty = try roundTrip(.mountUnmount(name: name, force: force))
    }

    public func mountStatus() throws -> MountStatusData {
        return try roundTrip(.mountStatus)
    }

    /// Send `attach`, read the framed `{ok}` reply, then detach the raw fd; the
    /// connection is now a byte pipe to the guest PTY (the caller owns the fd).
    public func attachRaw(sessionID: UInt64, token: String) throws -> Int32 {
        precondition(!token.isEmpty, "attach token must not be empty")
        lock.lock()
        defer { lock.unlock() }
        try framed.send(try LocalRequest.attach(sessionID: sessionID, token: token).encoded())
        let reply = try LocalResponse<LocalEmpty>.decode(try framed.receive())
        guard reply.ok else {
            throw MSLError.remote(reply.error ?? "attach rejected")
        }
        return framed.detachDescriptor()
    }

    /// Send `gui_connect`, read the framed `{ok}` reply, then detach the raw fd;
    /// the connection is now a byte pipe to the guest surface plane (vsock 5020).
    public func guiConnectRaw(name: String?) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        try framed.send(try LocalRequest.guiConnect(name: name).encoded())
        let reply = try LocalResponse<LocalEmpty>.decode(try framed.receive())
        guard reply.ok else {
            throw MSLError.remote(reply.error ?? "gui connect rejected")
        }
        return framed.detachDescriptor()
    }

    private func roundTrip<Payload: Decodable & Sendable>(
        _ request: LocalRequest
    ) throws -> Payload {
        lock.lock()
        defer { lock.unlock() }
        try framed.send(try request.encoded())
        let reply = try LocalResponse<Payload>.decode(try framed.receive())
        guard reply.ok, let data = reply.data else {
            throw MSLError.remote(reply.error ?? "request failed")
        }
        return data
    }
}

extension LocalClient: SessionControlChannel {
    public func sessionResize(sessionID: UInt64, rows: UInt16, cols: UInt16) throws {
        let _: LocalEmpty = try roundTrip(.resize(sessionID: sessionID, rows: rows, cols: cols))
    }

    public func sessionWait(sessionID: UInt64) throws -> SessionWaitData {
        let waited: LocalWaitData = try roundTrip(.wait(sessionID: sessionID))
        return SessionWaitData(done: waited.done, exitCode: waited.exitCode)
    }
}
