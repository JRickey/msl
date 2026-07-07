import Foundation

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
/// older clients can decode newer daemon replies.
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
