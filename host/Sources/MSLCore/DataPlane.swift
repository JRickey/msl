import Foundation

/// Opens a guest PTY data-plane connection (port 5001): connect, send the framed
/// `{session_id, token}` handshake, verify the reply, then hand back the raw
/// blocking fd for byte streaming. Shared by `msl up` and the resident daemon.
public enum DataPlane {
    /// Connect + handshake for `sessionID`/`token`; returns the detached raw fd.
    public static func open(
        host: any VMBackend, sessionID: UInt64, token: String, timeout: Double
    ) throws -> Int32 {
        precondition(!token.isEmpty, "data token must not be empty")
        precondition(timeout > 0, "data connect timeout must be positive")
        let fd = try host.connectRaw(port: Proto.dataPort, timeout: timeout)
        let framed = try VsockClient(fileDescriptor: fd)
        try framed.setReceiveTimeout(seconds: timeout)
        try framed.send(try DataHandshake(sessionID: sessionID, token: token).encoded())
        let reply = try DataHandshakeReply.decode(try framed.receive())
        guard reply.ok else {
            framed.close()
            throw MSLError.protocolMismatch("data handshake rejected: \(reply.error ?? "unknown")")
        }
        return framed.detachDescriptor()
    }
}
