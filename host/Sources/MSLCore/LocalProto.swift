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
/// sequentially; `attach` and `guiAttach` are terminal (the connection then goes
/// raw). There is no untokenized path to the guest surface plane: `guiToken`
/// mints a single-use token that `guiAttach` consumes.
public enum LocalRequest: Sendable, Equatable {
    case status
    case up(name: String?)
    case down(name: String?, all: Bool, timeoutMs: UInt64?)
    case shell(ShellRequest)
    case capture(ShellRequest)
    case attach(sessionID: UInt64, token: String)
    case guiToken(name: String?, user: String?)
    case guiAttach(distro: String, user: String?, token: String)
    case guiProbe(GuiRuntimeReq)
    case guiStart(GuiRuntimeReq)
    case guiStatus(GuiRuntimeReq)
    case guiStop(GuiRuntimeReq)
    case guiLaunch(GuiLaunchReq)
    case resize(sessionID: UInt64, rows: UInt16, cols: UInt16)
    case signal(sessionID: UInt64, signal: Int32)
    case wait(sessionID: UInt64)
    case mountPrepare(name: String?, readonly: Bool)
    case mountCommit(name: String, mountpoint: String)
    case mountUnmount(name: String, force: Bool)
    case mountStatus
    case authStatus(name: String?)
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
        case op, name, all, argv, env, rows, cols, cwd, token, signal, mountpoint, force, readonly
        case distro, user
        case timeoutMs = "timeout_ms"
        case sessionID = "session_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status, .shutdown, .up, .authStatus:
            try encodeBare(into: &container)
        case .down(let name, let all, let timeoutMs):
            try container.encode("down", forKey: .op)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(all, forKey: .all)
            try container.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
        case .shell(let req): try encodeShell(req, into: &container, op: "shell")
        case .capture(let req): try encodeShell(req, into: &container, op: "capture")
        case .guiProbe, .guiStart, .guiStatus, .guiStop, .guiLaunch, .guiToken, .guiAttach:
            try encodeGui(into: &container)
        case .attach, .resize, .signal, .wait: try encodeSession(into: &container)
        case .mountPrepare, .mountCommit, .mountUnmount, .mountStatus:
            try encodeMount(into: &container)
        }
    }

    /// Ops whose wire form is an op tag plus an optional distro name.
    private func encodeBare(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .status: try container.encode("status", forKey: .op)
        case .shutdown: try container.encode("shutdown", forKey: .op)
        case .up(let name): try encodeNamed("up", name, into: &container)
        case .authStatus(let name): try encodeNamed("auth_status", name, into: &container)
        default: break
        }
    }

    private func encodeNamed(
        _ op: String, _ name: String?, into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        assert(!op.isEmpty, "local op tag must not be empty")
        assert(name.map { !$0.isEmpty } ?? true, "distro name must not be empty when present")
        try container.encode(op, forKey: .op)
        try container.encodeIfPresent(name, forKey: .name)
    }

    private func encodeGui(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .guiProbe(let req):
            try encodeGuiRuntime(req, into: &container, op: "gui_probe")
        case .guiStart(let req):
            try encodeGuiRuntime(req, into: &container, op: "gui_start")
        case .guiStatus(let req):
            try encodeGuiRuntime(req, into: &container, op: "gui_status")
        case .guiStop(let req):
            try encodeGuiRuntime(req, into: &container, op: "gui_stop")
        case .guiLaunch(let req):
            try container.encode("gui_launch", forKey: .op)
            try container.encode(req.distro, forKey: .distro)
            try container.encodeIfPresent(req.user, forKey: .user)
            try container.encode(req.argv, forKey: .argv)
            try container.encode(req.env, forKey: .env)
            try container.encodeIfPresent(req.cwd, forKey: .cwd)
        case .guiToken(let name, let user):
            try container.encode("gui_token", forKey: .op)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(user, forKey: .user)
        case .guiAttach(let distro, let user, let token):
            try container.encode("gui_attach", forKey: .op)
            try container.encode(distro, forKey: .distro)
            try container.encodeIfPresent(user, forKey: .user)
            try container.encode(token, forKey: .token)
        default: break
        }
    }

    private func encodeGuiRuntime(
        _ req: GuiRuntimeReq, into container: inout KeyedEncodingContainer<CodingKeys>, op: String
    ) throws {
        try container.encode(op, forKey: .op)
        try container.encode(req.distro, forKey: .distro)
        try container.encodeIfPresent(req.user, forKey: .user)
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
        case .mountPrepare(let name, let readonly):
            try container.encode("mount_prepare", forKey: .op)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(readonly, forKey: .readonly)
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
        _ req: ShellRequest, into container: inout KeyedEncodingContainer<CodingKeys>, op: String
    ) throws {
        try container.encode(op, forKey: .op)
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
        case "capture": return .capture(try decodeShell(from: container))
        case "auth_status":
            return .authStatus(name: try container.decodeIfPresent(String.self, forKey: .name))
        case "shutdown": return .shutdown
        default: return try decodeGuiOp(op, from: container)
        }
    }

    private static func decodeGuiOp(
        _ op: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> LocalRequest {
        switch op {
        case "gui_probe": return .guiProbe(try decodeGuiRuntime(from: container))
        case "gui_start": return .guiStart(try decodeGuiRuntime(from: container))
        case "gui_status": return .guiStatus(try decodeGuiRuntime(from: container))
        case "gui_stop": return .guiStop(try decodeGuiRuntime(from: container))
        case "gui_launch": return .guiLaunch(try decodeGuiLaunch(from: container))
        case "gui_token":
            return .guiToken(
                name: try container.decodeIfPresent(String.self, forKey: .name),
                user: try container.decodeIfPresent(String.self, forKey: .user))
        case "gui_attach":
            return .guiAttach(
                distro: try container.decode(String.self, forKey: .distro),
                user: try container.decodeIfPresent(String.self, forKey: .user),
                token: try container.decode(String.self, forKey: .token))
        default: return try decodeMountOp(op, from: container)
        }
    }

    private static func decodeMountOp(
        _ op: String, from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> LocalRequest {
        switch op {
        case "mount_prepare":
            return .mountPrepare(
                name: try container.decodeIfPresent(String.self, forKey: .name),
                readonly: try container.decodeIfPresent(Bool.self, forKey: .readonly) ?? true)
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

    private static func decodeGuiRuntime(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> GuiRuntimeReq {
        return GuiRuntimeReq(
            distro: try container.decode(String.self, forKey: .distro),
            user: try container.decodeIfPresent(String.self, forKey: .user))
    }

    private static func decodeGuiLaunch(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> GuiLaunchReq {
        return GuiLaunchReq(
            distro: try container.decode(String.self, forKey: .distro),
            user: try container.decodeIfPresent(String.self, forKey: .user),
            argv: try container.decode([String].self, forKey: .argv),
            env: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd))
    }
}
