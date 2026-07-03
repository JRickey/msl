import Foundation

/// Wire types for the reverse interop channel (mac_exec v1,
/// docs/specs/m3a-protocol.md). Framed with the same length-prefix as the agent
/// control protocol but versioned independently.

/// Channel tag prefixing every mac_exec data frame.
public enum InteropTag: UInt8 {
    case stdin = 0
    case stdout = 1
    case stderr = 2
    case exit = 3
    case winch = 4
    case stdinEOF = 5
}

/// Hello sent shim -> host on the interop channel. Absent fields decode to
/// benign defaults; `validate()` enforces the wire contract before use.
public struct MacExecHello: Decodable, Sendable {
    public let ver: Int
    public let op: String
    public let argv: [String]
    public let cwd: String
    public let env: [String: String]
    public let tty: Bool
    public let rows: UInt16
    public let cols: UInt16

    static let maxArgv = 1024

    enum CodingKeys: String, CodingKey {
        case ver = "v"
        case op, argv, cwd, env, tty, rows, cols
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ver = try container.decodeIfPresent(Int.self, forKey: .ver) ?? 0
        op = try container.decodeIfPresent(String.self, forKey: .op) ?? ""
        argv = try container.decodeIfPresent([String].self, forKey: .argv) ?? []
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        tty = try container.decodeIfPresent(Bool.self, forKey: .tty) ?? false
        rows = try container.decodeIfPresent(UInt16.self, forKey: .rows) ?? 0
        cols = try container.decodeIfPresent(UInt16.self, forKey: .cols) ?? 0
    }

    /// Reject anything the spawner cannot honor. Recovery is the throw itself:
    /// the caller answers `{ok:false}` and closes.
    public func validate() throws {
        guard ver == 1 else { throw MSLError.protocolMismatch("mac_exec v=\(ver) unsupported") }
        guard op == "mac_exec" else { throw MSLError.protocolMismatch("mac_exec op=\(op)") }
        guard !argv.isEmpty else { throw MSLError.invalidArgument("mac_exec argv is empty") }
        guard argv.count <= Self.maxArgv else {
            throw MSLError.invalidArgument("mac_exec argv exceeds \(Self.maxArgv)")
        }
        assert(!argv.isEmpty, "argv emptiness already rejected above")
    }

    /// Hello frames are capped well below the 4 MiB transport bound.
    public static let maxHelloBytes = 256 * 1024

    /// Decode + validate one framed hello, enforcing the protocol's own 256 KiB
    /// hello bound before any JSON parsing.
    public static func decode(_ bytes: Data) throws -> MacExecHello {
        guard !bytes.isEmpty else { throw MSLError.protocolMismatch("empty mac_exec hello") }
        guard bytes.count <= Self.maxHelloBytes else {
            throw MSLError.framing("mac_exec hello \(bytes.count) exceeds \(Self.maxHelloBytes)")
        }
        let hello = try JSONDecoder().decode(MacExecHello.self, from: bytes)
        try hello.validate()
        return hello
    }
}

/// Host -> shim hello reply: `{ok}` or `{ok:false,error}` then close.
public struct InteropReply: Encodable, Sendable {
    public let ok: Bool
    public let error: String?

    public static func ok() -> InteropReply { InteropReply(ok: true, error: nil) }

    public static func failure(_ message: String) -> InteropReply {
        precondition(!message.isEmpty, "failure reply needs a message")
        return InteropReply(ok: false, error: message)
    }

    /// Encode to a UTF-8 JSON frame payload, enforcing the 4 MiB bound.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("reply payload \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }
}

/// Host -> shim exit frame body (tag 3): the propagated child status.
public struct InteropExit: Encodable, Sendable {
    public let code: Int32

    /// Encode the `{code}` body; a status JSON never approaches the frame cap.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        assert(data.count <= Proto.maxPayload, "exit body is a tiny fixed JSON")
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("exit payload \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }
}

/// Shim -> host resize frame body (tag 4): the new tty dimensions.
public struct InteropResize: Decodable, Sendable {
    public let rows: UInt16
    public let cols: UInt16
}
