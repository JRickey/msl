import Foundation

/// Wire types for the local client <-> daemon protocol (docs/specs/m2c-daemon.md).
/// Encoded as UTF-8 JSON inside the same length-prefixed frames as the vsock
/// control plane; `VsockClient` carries the frames over the unix socket.
public enum LocalProto {
    /// Unix-socket basename under `$MSL_HOME`; created 0600, owner-only.
    public static let socketName = "msld.sock"

    /// PID file basename under `$MSL_HOME` written by `msl daemon run`.
    public static let pidName = "msld.pid"

    /// Daemon log basename under `$MSL_HOME/logs` for the auto-spawn path.
    public static let logName = "msld.log"

    /// Token length in hex characters (16 random bytes), same as the guest plane.
    public static let tokenHexLength = 32
}

/// One request from a client connection. A connection may issue many of these
/// sequentially; `attach` is terminal (the connection then goes raw).
public enum LocalRequest: Sendable, Equatable {
    case status
    case up(name: String?)
    case down(name: String?, all: Bool, timeoutMs: UInt64?)
    case shell(ShellRequest)
    case attach(sessionID: UInt64, token: String)
    case guiConnect(name: String?)
    case resize(sessionID: UInt64, rows: UInt16, cols: UInt16)
    case signal(sessionID: UInt64, signal: Int32)
    case wait(sessionID: UInt64)
    case mountPrepare(name: String?)
    case mountCommit(name: String, mountpoint: String)
    case mountUnmount(name: String, force: Bool)
    case mountStatus
    case shutdown

    /// Encode to a UTF-8 JSON frame payload, enforcing the 4 MiB bound.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("local request \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }

    /// Decode one framed request payload.
    public static func decode(_ bytes: Data) throws -> LocalRequest {
        guard !bytes.isEmpty else { throw MSLError.protocolMismatch("empty local request") }
        return try JSONDecoder().decode(LocalRequest.self, from: bytes)
    }
}

/// `shell`/`run` request body: which distro, the argv (nil = login shell),
/// environment, the initial window size, and the mapped guest cwd.
public struct ShellRequest: Sendable, Equatable, Codable {
    public let name: String?
    public let argv: [String]?
    public let env: [String: String]?
    public let rows: UInt16
    public let cols: UInt16
    public let cwd: String?

    public init(
        name: String?, argv: [String]?, env: [String: String]?, rows: UInt16, cols: UInt16,
        cwd: String?
    ) {
        precondition(rows > 0, "shell rows must be positive")
        precondition(cols > 0, "shell cols must be positive")
        self.name = name
        self.argv = argv
        self.env = env
        self.rows = rows
        self.cols = cols
        self.cwd = cwd
    }
}

extension LocalRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, name, all, argv, env, rows, cols, cwd, token, signal, mountpoint, force
        case timeoutMs = "timeout_ms"
        case sessionID = "session_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try container.encode("status", forKey: .op)
        case .up(let name):
            try container.encode("up", forKey: .op)
            try container.encodeIfPresent(name, forKey: .name)
        case .down(let name, let all, let timeoutMs):
            try container.encode("down", forKey: .op)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(all, forKey: .all)
            try container.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
        case .shell(let req): try encodeShell(req, into: &container)
        case .guiConnect(let name):
            try container.encode("gui_connect", forKey: .op)
            try container.encodeIfPresent(name, forKey: .name)
        case .shutdown: try container.encode("shutdown", forKey: .op)
        case .attach, .resize, .signal, .wait: try encodeSession(into: &container)
        case .mountPrepare, .mountCommit, .mountUnmount, .mountStatus:
            try encodeMount(into: &container)
        }
    }

    private func encodeSession(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .attach(let sessionID, let token):
            try container.encode("attach", forKey: .op)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(token, forKey: .token)
        case .resize(let sessionID, let rows, let cols):
            try container.encode("resize", forKey: .op)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(rows, forKey: .rows)
            try container.encode(cols, forKey: .cols)
        case .signal(let sessionID, let signal):
            try container.encode("signal", forKey: .op)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(signal, forKey: .signal)
        case .wait(let sessionID):
            try container.encode("wait", forKey: .op)
            try container.encode(sessionID, forKey: .sessionID)
        default: break
        }
    }

    private func encodeMount(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .mountPrepare(let name):
            try container.encode("mount_prepare", forKey: .op)
            try container.encodeIfPresent(name, forKey: .name)
        case .mountCommit(let name, let mountpoint):
            try container.encode("mount_commit", forKey: .op)
            try container.encode(name, forKey: .name)
            try container.encode(mountpoint, forKey: .mountpoint)
        case .mountUnmount(let name, let force):
            try container.encode("mount_unmount", forKey: .op)
            try container.encode(name, forKey: .name)
            try container.encode(force, forKey: .force)
        case .mountStatus: try container.encode("mount_status", forKey: .op)
        default: break
        }
    }

    private func encodeShell(
        _ req: ShellRequest, into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode("shell", forKey: .op)
        try container.encodeIfPresent(req.name, forKey: .name)
        try container.encodeIfPresent(req.argv, forKey: .argv)
        try container.encodeIfPresent(req.env, forKey: .env)
        try container.encode(req.rows, forKey: .rows)
        try container.encode(req.cols, forKey: .cols)
        try container.encodeIfPresent(req.cwd, forKey: .cwd)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)
        self = try Self.decodeOp(op, from: container)
    }

    private static func decodeOp(
        _ op: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> LocalRequest {
        switch op {
        case "status": return .status
        case "up": return .up(name: try container.decodeIfPresent(String.self, forKey: .name))
        case "down":
            return .down(
                name: try container.decodeIfPresent(String.self, forKey: .name),
                all: try container.decodeIfPresent(Bool.self, forKey: .all) ?? false,
                timeoutMs: try container.decodeIfPresent(UInt64.self, forKey: .timeoutMs))
        case "shell": return .shell(try decodeShell(from: container))
        case "gui_connect":
            return .guiConnect(name: try container.decodeIfPresent(String.self, forKey: .name))
        case "shutdown": return .shutdown
        default: return try decodeMountOp(op, from: container)
        }
    }

    private static func decodeMountOp(
        _ op: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> LocalRequest {
        switch op {
        case "mount_prepare":
            return .mountPrepare(name: try container.decodeIfPresent(String.self, forKey: .name))
        case "mount_commit":
            return .mountCommit(
                name: try container.decode(String.self, forKey: .name),
                mountpoint: try container.decode(String.self, forKey: .mountpoint))
        case "mount_unmount":
            return .mountUnmount(
                name: try container.decode(String.self, forKey: .name),
                force: try container.decodeIfPresent(Bool.self, forKey: .force) ?? false)
        case "mount_status": return .mountStatus
        default: return try decodeSessionOp(op, from: container)
        }
    }

    private static func decodeSessionOp(
        _ op: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> LocalRequest {
        switch op {
        case "attach":
            return .attach(
                sessionID: try container.decode(UInt64.self, forKey: .sessionID),
                token: try container.decode(String.self, forKey: .token))
        case "resize":
            return .resize(
                sessionID: try container.decode(UInt64.self, forKey: .sessionID),
                rows: try container.decode(UInt16.self, forKey: .rows),
                cols: try container.decode(UInt16.self, forKey: .cols))
        case "signal":
            return .signal(
                sessionID: try container.decode(UInt64.self, forKey: .sessionID),
                signal: try container.decode(Int32.self, forKey: .signal))
        case "wait": return .wait(sessionID: try container.decode(UInt64.self, forKey: .sessionID))
        default: throw MSLError.protocolMismatch("unknown local op: \(op)")
        }
    }

    private static func decodeShell(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ShellRequest {
        return ShellRequest(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            argv: try container.decodeIfPresent([String].self, forKey: .argv),
            env: try container.decodeIfPresent([String: String].self, forKey: .env),
            rows: try container.decodeIfPresent(UInt16.self, forKey: .rows) ?? 40,
            cols: try container.decodeIfPresent(UInt16.self, forKey: .cols) ?? 120,
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd))
    }
}

/// One distro's line in the `status` reply: name, lifecycle state, live sessions.
public struct DistroStatus: Sendable, Equatable, Codable {
    public let name: String
    public let state: String
    public let sessions: Int

    public init(name: String, state: String, sessions: Int) {
        self.name = name
        self.state = state
        self.sessions = sessions
    }
}

/// Balloon memory summary in the `status` reply (nil when the VM is stopped).
public struct MemoryStatus: Sendable, Equatable, Codable {
    public let targetMiB: UInt64
    public let maxMiB: UInt64
    public let availableMiB: UInt64

    enum CodingKeys: String, CodingKey {
        case targetMiB = "target_mib"
        case maxMiB = "max_mib"
        case availableMiB = "available_mib"
    }

    public init(targetMiB: UInt64, maxMiB: UInt64, availableMiB: UInt64) {
        self.targetMiB = targetMiB
        self.maxMiB = maxMiB
        self.availableMiB = availableMiB
    }
}

/// Payload of the `status` reply. `memory` and `forwardedPorts` are optional so
/// a v1.2 client decodes a v1.3 reply (and vice versa).
public struct StatusData: Sendable, Equatable, Codable {
    public let vm: String
    public let distros: [DistroStatus]
    public let idleTimeoutS: Int
    public let memory: MemoryStatus?
    public let forwardedPorts: [UInt16]?

    enum CodingKeys: String, CodingKey {
        case vm, distros, memory
        case idleTimeoutS = "idle_timeout_s"
        case forwardedPorts = "forwarded_ports"
    }

    public init(
        vm: String, distros: [DistroStatus], idleTimeoutS: Int,
        memory: MemoryStatus? = nil, forwardedPorts: [UInt16]? = nil
    ) {
        self.vm = vm
        self.distros = distros
        self.idleTimeoutS = idleTimeoutS
        self.memory = memory
        self.forwardedPorts = forwardedPorts
    }
}

/// Payload of the `shell`/`run` reply: the guest session id and the single-use
/// local attach token.
public struct ShellData: Sendable, Equatable, Codable {
    public let sessionID: UInt64
    public let token: String

    enum CodingKeys: String, CodingKey {
        case token
        case sessionID = "session_id"
    }

    public init(sessionID: UInt64, token: String) {
        precondition(!token.isEmpty, "session token must not be empty")
        self.sessionID = sessionID
        self.token = token
    }
}

/// Payload of the `wait` reply (mirrors the guest `session_wait`: non-blocking).
public struct LocalWaitData: Sendable, Equatable, Codable {
    public let done: Bool
    public let exitCode: Int32?

    enum CodingKeys: String, CodingKey {
        case done
        case exitCode = "exit_code"
    }

    public init(done: Bool, exitCode: Int32?) {
        self.done = done
        self.exitCode = exitCode
    }
}

/// Empty `{}` reply payload for ops whose success carries no data.
public struct LocalEmpty: Sendable, Equatable, Codable {
    public init() {}
}

/// Decoded reply envelope on the client side. `data` is present when `ok`.
public struct LocalResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    public let ok: Bool
    public let data: Payload?
    public let error: String?

    /// Decode a reply, validating the ok/data and error invariants.
    public static func decode(_ bytes: Data) throws -> LocalResponse<Payload> {
        guard !bytes.isEmpty else { throw MSLError.protocolMismatch("empty local reply") }
        let value = try JSONDecoder().decode(LocalResponse<Payload>.self, from: bytes)
        if value.ok {
            guard value.data != nil else {
                throw MSLError.protocolMismatch("ok reply missing data")
            }
        } else {
            guard let message = value.error, !message.isEmpty else {
                throw MSLError.protocolMismatch("error reply missing error text")
            }
        }
        return value
    }
}

/// Builds reply frames on the daemon side (encode side of `LocalResponse`).
public enum LocalReply {
    /// Encode `{"ok":true,"data":<payload>}`.
    public static func ok<Payload: Encodable>(_ payload: Payload) throws -> Data {
        let data = try JSONEncoder().encode(OkEnvelope(data: payload))
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("local reply \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }

    /// Encode `{"ok":false,"error":<message>}`.
    public static func error(_ message: String) throws -> Data {
        precondition(!message.isEmpty, "error message must not be empty")
        let data = try JSONEncoder().encode(ErrorEnvelope(error: message))
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("local reply \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }

    private struct OkEnvelope<Payload: Encodable>: Encodable {
        let ok = true
        let data: Payload
    }

    private struct ErrorEnvelope: Encodable {
        let ok = false
        let error: String
    }
}
