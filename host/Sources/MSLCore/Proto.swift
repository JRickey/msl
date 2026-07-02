import Foundation

/// Wire types for msl-agent v0 (docs/specs/m0-protocol.md). Encoded as UTF-8
/// JSON inside the length-prefixed frames implemented by `VsockClient`.
public enum Proto {
    /// Maximum JSON payload per frame; frames above this are rejected before
    /// any allocation, per the protocol bound.
    public static let maxPayload = 4 * 1024 * 1024

    /// Agent control port (any guest CID).
    public static let port: UInt32 = 5000

    /// PTY session data-plane port (framed token handshake, then raw bytes).
    public static let dataPort: UInt32 = 5001

    /// Agent -> host log-event port (optional reader).
    public static let logsPort: UInt32 = 5002

    /// Wire protocol version advertised by a v1 agent in the `ping` reply.
    public static let version = 1
}

/// Request sent host -> agent. `argv`, `env`, and `timeoutMs` apply to exec;
/// `distro`/`cwd` are v1 exec additions (run inside the distro namespaces).
public struct Request: Encodable, Sendable {
    public let id: UInt64
    public let op: String
    public let argv: [String]?
    public let env: [String: String]?
    public let timeoutMs: UInt64?
    public let distro: Bool?
    public let cwd: String?

    enum CodingKeys: String, CodingKey {
        case id, op, argv, env, distro, cwd
        case timeoutMs = "timeout_ms"
    }

    public static func ping(id: UInt64) -> Request {
        precondition(id > 0, "request id must be positive")
        return Request(
            id: id, op: "ping", argv: nil, env: nil, timeoutMs: nil, distro: nil, cwd: nil)
    }

    public static func exec(
        id: UInt64, argv: [String], env: [String: String]?, timeoutMs: UInt64,
        distro: Bool? = nil, cwd: String? = nil
    ) -> Request {
        precondition(id > 0, "request id must be positive")
        precondition(!argv.isEmpty, "argv must be non-empty")
        return Request(
            id: id, op: "exec", argv: argv, env: env, timeoutMs: timeoutMs, distro: distro,
            cwd: cwd)
    }

    /// Encode to a UTF-8 JSON frame payload, enforcing the 4 MiB bound.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("request payload \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }
}

/// v1 control request carrying a nested `req` object (distro/session/time ops).
/// `req` is optional so `distro_state` encodes as `{id, op}` with no body.
public struct OpRequest<Req: Encodable & Sendable>: Encodable, Sendable {
    public let id: UInt64
    public let op: String
    public let req: Req?

    public init(id: UInt64, op: String, req: Req?) {
        precondition(id > 0, "request id must be positive")
        precondition(!op.isEmpty, "op must not be empty")
        self.id = id
        self.op = op
        self.req = req
    }

    /// Encode to a UTF-8 JSON frame payload, enforcing the 4 MiB bound.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("request payload \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }
}

/// `req` body for `distro_up`.
public struct DistroUpReq: Encodable, Sendable {
    public let dev: String
    public let hostname: String
    public let macShare: Bool

    enum CodingKeys: String, CodingKey {
        case dev, hostname
        case macShare = "mac_share"
    }
}

/// `req` body for `session_open`.
public struct SessionOpenReq: Encodable, Sendable {
    public let argv: [String]
    public let cwd: String
    public let env: [String: String]
    public let rows: UInt16
    public let cols: UInt16
    public let distro: Bool
}

/// `req` body for `session_resize`.
public struct SessionResizeReq: Encodable, Sendable {
    public let sessionID: UInt64
    public let rows: UInt16
    public let cols: UInt16

    enum CodingKeys: String, CodingKey {
        case rows, cols
        case sessionID = "session_id"
    }
}

/// `req` body for `session_signal`.
public struct SessionSignalReq: Encodable, Sendable {
    public let sessionID: UInt64
    public let signal: Int32

    enum CodingKeys: String, CodingKey {
        case signal
        case sessionID = "session_id"
    }
}

/// `req` body for `session_wait`.
public struct SessionWaitReq: Encodable, Sendable {
    public let sessionID: UInt64

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

/// `req` body for `set_time` (host wall clock as seconds + microseconds).
public struct SetTimeReq: Encodable, Sendable {
    public let sec: Int64
    public let usec: Int64
}

/// Framed handshake sent on the data plane (5001) before raw byte streaming.
public struct DataHandshake: Encodable, Sendable {
    public let sessionID: UInt64
    public let token: String

    enum CodingKeys: String, CodingKey {
        case token
        case sessionID = "session_id"
    }

    /// Encode to a UTF-8 JSON frame payload, enforcing the 4 MiB bound.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("handshake payload \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }
}

/// Reply to the data handshake; `ok:false` carries an error and closes.
public struct DataHandshakeReply: Decodable, Sendable {
    public let ok: Bool
    public let error: String?

    /// Decode the bare `{ok,...}` reply (no id/op envelope on the data plane).
    public static func decode(_ bytes: Data) throws -> DataHandshakeReply {
        guard !bytes.isEmpty else { throw MSLError.protocolMismatch("empty handshake reply") }
        return try JSONDecoder().decode(DataHandshakeReply.self, from: bytes)
    }
}

/// Payload of `distro_up` / `distro_state`.
public struct DistroData: Decodable, Sendable {
    public let state: String
    public let initPid: UInt32?

    enum CodingKeys: String, CodingKey {
        case state
        case initPid = "init_pid"
    }
}

/// Payload of `session_open`.
public struct SessionOpenData: Decodable, Sendable {
    public let sessionID: UInt64
    public let token: String

    enum CodingKeys: String, CodingKey {
        case token
        case sessionID = "session_id"
    }
}

/// Payload of `session_wait` (non-blocking; `done` false until the child exits).
public struct SessionWaitData: Decodable, Sendable {
    public let done: Bool
    public let exitCode: Int32?

    enum CodingKeys: String, CodingKey {
        case done
        case exitCode = "exit_code"
    }
}

/// Empty `{}` payload for ops whose success carries no data.
public struct EmptyData: Decodable, Sendable {}

/// Payload of `ping`; all fields optional so an older agent still parses.
/// `protocolVersion` is the v1 addition (absent on a v0 agent).
public struct PingData: Decodable, Sendable {
    public let agent: String?
    public let version: String?
    public let kernel: String?
    public let protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case agent, version, kernel
        case protocolVersion = "protocol"
    }
}

/// Payload of a successful `exec` response.
public struct ExecData: Decodable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case exitCode = "exit_code"
        case stdout, stderr, truncated
    }
}

/// Generic response envelope. `data` is present when `ok` is true; `error`
/// carries the agent-supplied message otherwise.
public struct Response<Payload: Decodable>: Decodable, Sendable where Payload: Sendable {
    public let id: UInt64
    public let ok: Bool
    public let data: Payload?
    public let error: String?

    /// Decode a response payload, validating the envelope invariants.
    public static func decode(_ bytes: Data, expectedID: UInt64) throws -> Response<Payload> {
        guard !bytes.isEmpty else {
            throw MSLError.protocolMismatch("empty response frame")
        }
        let value = try JSONDecoder().decode(Response<Payload>.self, from: bytes)
        guard value.id == expectedID else {
            throw MSLError.protocolMismatch("response id \(value.id) != request id \(expectedID)")
        }
        if value.ok {
            guard value.data != nil else {
                throw MSLError.protocolMismatch("ok response missing data")
            }
        } else {
            guard let message = value.error, !message.isEmpty else {
                throw MSLError.protocolMismatch("error response missing error text")
            }
        }
        return value
    }
}
