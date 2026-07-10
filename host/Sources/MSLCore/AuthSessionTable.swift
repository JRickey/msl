import Foundation

public struct AuthSession: Equatable, Sendable {
    public let id: String
    public let token: String
    public let distro: String
    public let sshAgent: Bool
    public let sshAgentForwarding: Bool
    public let secrets: Bool
    public var guestSessionID: UInt64?

    public var environment: [String: String] {
        var env = [
            "MSL_AUTH_ID": id,
            "MSL_AUTH_TOKEN": token,
            "MSL_AUTH_DISTRO": distro,
            "MSL_AUTH_PORT": String(Proto.authPort),
            "MSL_AUTH_SSH": sshAgent ? "1" : "0",
            "MSL_AUTH_SSH_FORWARDING": sshAgentForwarding ? "1" : "0",
            "MSL_AUTH_SECRETS": secrets ? "1" : "0",
        ]
        env["MSL_AUTH_VERSION"] = "1"
        return env
    }
}

public final class AuthSessionTable: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: AuthSession] = [:]
    private var idByGuestSession: [UInt64: String] = [:]

    public init() {}

    public func create(
        distro: String, sshAgent: Bool, sshAgentForwarding: Bool = false, secrets: Bool
    ) -> AuthSession {
        precondition(!distro.isEmpty, "auth session distro must not be empty")
        let session = AuthSession(
            id: Token.generate(), token: Token.generate(), distro: distro,
            sshAgent: sshAgent, sshAgentForwarding: sshAgentForwarding, secrets: secrets,
            guestSessionID: nil)
        lock.lock()
        byID[session.id] = session
        lock.unlock()
        return session
    }

    public func bind(authID: String, guestSessionID: UInt64) {
        precondition(!authID.isEmpty, "auth id must not be empty")
        precondition(guestSessionID > 0, "guest session id must be positive")
        lock.lock()
        defer { lock.unlock() }
        guard var session = byID[authID] else { return }
        session.guestSessionID = guestSessionID
        byID[authID] = session
        idByGuestSession[guestSessionID] = authID
    }

    public func removeGuestSession(_ guestSessionID: UInt64) {
        precondition(guestSessionID > 0, "guest session id must be positive")
        lock.lock()
        defer { lock.unlock() }
        guard let authID = idByGuestSession.removeValue(forKey: guestSessionID) else { return }
        byID[authID] = nil
    }

    public func remove(_ authID: String) {
        precondition(!authID.isEmpty, "auth id must not be empty")
        lock.lock()
        defer { lock.unlock() }
        guard let session = byID.removeValue(forKey: authID),
            let guest = session.guestSessionID
        else { return }
        idByGuestSession[guest] = nil
    }

    public func removeAll() {
        lock.lock()
        byID = [:]
        idByGuestSession = [:]
        lock.unlock()
    }

    /// Attribution: live token, matching distro, distro still running, surface
    /// enabled by policy. `isRunning` is the daemon's view of the distro state.
    public func validate(
        _ peer: AuthPeer, surface: AuthSurface, isRunning: (String) -> Bool
    ) throws -> AuthSession {
        guard Registry.isValidName(peer.distro) else {
            throw AuthValidationError(code: .badRequest, message: "invalid distro")
        }
        guard !peer.id.isEmpty, !peer.token.isEmpty else {
            throw AuthValidationError(code: .denied, message: "bad auth session")
        }
        lock.lock()
        let session = byID[peer.id]
        lock.unlock()
        guard let session, Token.matches(session.token, peer.token),
            session.distro == peer.distro
        else {
            throw AuthValidationError(code: .denied, message: "bad auth session")
        }
        assert(session.distro == peer.distro, "matched session carries the peer's distro")
        guard isRunning(session.distro) else {
            throw AuthValidationError(code: .denied, message: "distro is not running")
        }
        switch surface {
        case .sshAgent where !session.sshAgent:
            throw AuthValidationError(code: .denied, message: "ssh-agent bridge disabled")
        case .secrets where !session.secrets:
            throw AuthValidationError(code: .denied, message: "secrets bridge disabled")
        default:
            return session
        }
    }
}

public struct AuthValidationError: Error, Equatable {
    public let code: AuthErrorCode
    public let message: String
}
