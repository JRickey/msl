import Foundation

/// Wire types for msl-agent v0 (docs/specs/m0-protocol.md). Encoded as UTF-8
/// JSON inside the length-prefixed frames implemented by `VsockClient`.
public enum Proto {
    /// Maximum JSON payload per frame; frames above this are rejected before
    /// any allocation, per the protocol bound.
    public static let maxPayload = 4 * 1024 * 1024

    /// Agent listening port (any guest CID).
    public static let port: UInt32 = 5000
}

/// Request sent host -> agent. `argv`, `env`, and `timeoutMs` apply to exec.
public struct Request: Encodable, Sendable {
    public let id: UInt64
    public let op: String
    public let argv: [String]?
    public let env: [String: String]?
    public let timeoutMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case id, op, argv, env
        case timeoutMs = "timeout_ms"
    }

    public static func ping(id: UInt64) -> Request {
        precondition(id > 0, "request id must be positive")
        return Request(id: id, op: "ping", argv: nil, env: nil, timeoutMs: nil)
    }

    public static func exec(
        id: UInt64, argv: [String], env: [String: String]?, timeoutMs: UInt64
    ) -> Request {
        precondition(id > 0, "request id must be positive")
        precondition(!argv.isEmpty, "argv must be non-empty")
        return Request(id: id, op: "exec", argv: argv, env: env, timeoutMs: timeoutMs)
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
