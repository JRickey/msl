import Darwin
import Foundation

/// Reverse-vsock auth bridge. Guest adapters hold one long-lived connection
/// each, so the daemon activity hold is taken per request, not per connection:
/// an attached-but-idle adapter must never keep the VM out of idle reclaim.
final class AuthBridgeListener: ReverseVsockHandler, @unchecked Sendable {
    private let sessions: AuthSessionTable
    private let sshProxy: HostSSHAgentProxy
    private let secrets: KeychainSecretStore
    private let logger: @Sendable (String) -> Void
    private let beginActivity: @Sendable () -> Void
    private let endActivity: @Sendable () -> Void
    private let isDistroRunning: @Sendable (String) -> Bool
    private let idleTimeout: Double
    private let requestTimeout: Double
    private let lock = NSLock()
    private var live = 0
    private var accepting = true

    static let maxConnections = 32
    /// Idle connections close after 30s; a started request must finish its frame
    /// within 10s. Both are spec bounds on the auth wire contract.
    static let idleTimeout = 30.0
    static let requestTimeout = 10.0
    static let maxRequestsPerConnection = 1 << 20

    init(
        sessions: AuthSessionTable, sshProxy: HostSSHAgentProxy,
        secrets: KeychainSecretStore,
        logger: @escaping @Sendable (String) -> Void,
        beginActivity: @escaping @Sendable () -> Void,
        endActivity: @escaping @Sendable () -> Void,
        isDistroRunning: @escaping @Sendable (String) -> Bool,
        idleTimeout: Double = AuthBridgeListener.idleTimeout,
        requestTimeout: Double = AuthBridgeListener.requestTimeout
    ) {
        precondition(idleTimeout > 0, "idle timeout must be positive")
        precondition(requestTimeout > 0, "request timeout must be positive")
        self.sessions = sessions
        self.sshProxy = sshProxy
        self.secrets = secrets
        self.logger = logger
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        self.isDistroRunning = isDistroRunning
        self.idleTimeout = idleTimeout
        self.requestTimeout = requestTimeout
    }

    func stop() {
        withLock { accepting = false }
    }

    /// VM-queue callback: must return fast. The adapter already dup'd the fd;
    /// admit and hand off to a detached serve thread.
    func handleReverseConnection(fd: Int32, port: UInt32) -> Bool {
        guard admit() else {
            _ = Darwin.close(fd)
            return false
        }
        Thread.detachNewThread { [self] in
            serve(fd: fd)
            withLock { live = max(0, live - 1) }
        }
        return true
    }

    func handleReverseAcceptFailure(errno code: Int32, port: UInt32) {
        logger("auth: dup failed errno=\(code)")
    }

    func admit() -> Bool {
        return withLock {
            guard accepting, live < Self.maxConnections else { return false }
            assert(live >= 0, "live connection count never goes negative")
            live += 1
            return true
        }
    }

    func serve(fd: Int32) {
        assert(fd >= 0, "accepted descriptors are valid")
        guard let framed = try? VsockClient(fileDescriptor: fd) else {
            _ = Darwin.close(fd)
            return
        }
        defer { framed.close() }
        for _ in 0..<Self.maxRequestsPerConnection {  // bounded: idle close ends it first
            guard AuthPoll.waitReadable(fd: fd, seconds: idleTimeout) else { return }
            guard (try? framed.setReceiveTimeout(seconds: requestTimeout)) != nil else {
                return
            }
            guard let data = try? framed.receive() else { return }
            let reply = respond(data)
            assert(!reply.isEmpty, "every request produces a reply frame")
            guard (try? framed.send(reply)) != nil else { return }
        }
        logger("auth: connection exceeded the per-connection request bound")
    }

    /// Hold a daemon activity reference for exactly the request round trip.
    private func respond(_ data: Data) -> Data {
        assert(!data.isEmpty, "receive returns a non-empty frame or throws")
        beginActivity()
        defer { endActivity() }
        return handle(data)
    }

    func handle(_ data: Data) -> Data {
        let request: AuthBridgeRequest
        let session: AuthSession
        do {
            request = try AuthBridgeRequest.decode(data)
            guard request.version == 1 else {
                throw AuthValidationError(code: .badRequest, message: "bad auth version")
            }
            session = try sessions.validate(
                request.session, surface: request.surface, isRunning: isDistroRunning)
        } catch let error as AuthValidationError {
            return AuthBridgeError.frame(id: 0, code: error.code, message: error.message)
        } catch {
            return AuthBridgeError.frame(id: 0, code: .badRequest, message: "bad auth request")
        }
        do {
            assert(session.distro == request.session.distro, "validate binds the distro")
            return try dispatch(request, session: session)
        } catch let error as AuthProxyError {
            return AuthBridgeError.frame(
                id: request.id, code: error.wireCode, message: error.wireMessage)
        } catch {
            return AuthBridgeError.frame(
                id: request.id, code: .internal, message: "auth bridge failed")
        }
    }

    private func dispatch(_ request: AuthBridgeRequest, session: AuthSession) throws -> Data {
        assert(request.version == 1, "handle rejects other versions")
        assert(!session.id.isEmpty, "validated sessions carry an id")
        switch request.surface {
        case .sshAgent:
            return try dispatchSSH(request, session: session)
        case .secrets:
            return try dispatchSecrets(request, session: session)
        }
    }

    private func dispatchSSH(_ request: AuthBridgeRequest, session: AuthSession) throws -> Data {
        assert(session.sshAgent, "validate rejects a disabled ssh-agent surface")
        assert(request.surface == .sshAgent, "dispatch routed by surface")
        switch (request.op, request.req) {
        case ("ssh.forward_packet", .sshForward(let body)):
            guard let encoded = body.packetBase64, let packet = Data(base64Encoded: encoded)
            else { throw AuthProxyError.badRequest("bad packet encoding") }
            let reply = try sshProxy.forward(
                packet: packet, forwarding: session.sshAgentForwarding)
            return try AuthBridgeReply.ok(
                id: request.id, SSHForwardReply(packetBase64: reply.base64EncodedString()))
        case ("ssh.query", _):
            let data = AuthQueryData(sshAgent: session.sshAgent, secrets: session.secrets)
            return try AuthBridgeReply.ok(id: request.id, data)
        default:
            throw AuthProxyError.denied("unsupported auth operation")
        }
    }

    private func dispatchSecrets(
        _ request: AuthBridgeRequest, session: AuthSession
    ) throws -> Data {
        assert(session.secrets, "validate rejects a disabled secrets surface")
        assert(request.surface == .secrets, "dispatch routed by surface")
        switch (request.op, request.req) {
        case ("secret.collection.list", _), ("secret.collection.ensure_default", _):
            let data = SecretCollectionData(collections: [KeychainSecretLimits.defaultCollection])
            return try AuthBridgeReply.ok(id: request.id, data)
        case ("secret.item.create", .secret(let body)):
            return try createSecret(request.id, body)
        case ("secret.item.search", _):
            let records = try secrets.search(attributes: secretBody(request).attributes ?? [:])
            let data = SecretItemsData(items: records.map(SecretItemSummary.init))
            return try AuthBridgeReply.ok(id: request.id, data)
        case ("secret.item.get", .secret(let body)):
            return try readSecret(request.id, body)
        case ("secret.item.set", .secret(let body)):
            return try updateSecret(request.id, body)
        case ("secret.item.delete", .secret(let body)):
            try secrets.delete(id: try itemID(body))
            return try AuthBridgeReply.ok(id: request.id, AuthEmpty())
        case ("secret.item.properties", .secret(let body)):
            return try secretProperties(request.id, body)
        default:
            throw AuthProxyError.denied("unsupported auth operation")
        }
    }

    private func createSecret(_ id: UInt64, _ body: SecretBridgeRequest) throws -> Data {
        assert(body.hasPayload, "the payload decoder produced a secret body")
        guard let encoded = body.secretBase64, let secret = Data(base64Encoded: encoded)
        else { throw AuthProxyError.badRequest("secret bytes are required") }
        let record = try secrets.create(
            label: body.label ?? "", attributes: body.attributes ?? [:], secret: secret)
        assert(!record.id.isEmpty, "created records carry an id")
        let data = SecretItemData(item: SecretItemSummary(record), secretBase64: nil)
        return try AuthBridgeReply.ok(id: id, data)
    }

    private func readSecret(_ id: UInt64, _ body: SecretBridgeRequest) throws -> Data {
        let record = try secrets.record(id: try itemID(body))
        let secret = try secrets.secret(id: record.id)
        assert(secret.count <= KeychainSecretLimits.maxSecretBytes, "stored bytes stay in bounds")
        let data = SecretItemData(
            item: SecretItemSummary(record), secretBase64: secret.base64EncodedString())
        return try AuthBridgeReply.ok(id: id, data)
    }

    private func updateSecret(_ id: UInt64, _ body: SecretBridgeRequest) throws -> Data {
        guard let encoded = body.secretBase64, let secret = Data(base64Encoded: encoded)
        else { throw AuthProxyError.badRequest("secret bytes are required") }
        let itemID = try itemID(body)
        let record = try secrets.update(id: itemID, secret: secret)
        assert(record.id == itemID, "update returns the same item")
        let data = SecretItemData(item: SecretItemSummary(record), secretBase64: nil)
        return try AuthBridgeReply.ok(id: id, data)
    }

    private func secretProperties(_ id: UInt64, _ body: SecretBridgeRequest) throws -> Data {
        let record = try secrets.record(id: try itemID(body))
        assert(!record.collection.isEmpty, "records carry a collection")
        let data = SecretItemData(item: SecretItemSummary(record), secretBase64: nil)
        return try AuthBridgeReply.ok(id: id, data)
    }

    private func itemID(_ body: SecretBridgeRequest) throws -> String {
        guard let itemID = body.itemID, !itemID.isEmpty else {
            throw AuthProxyError.badRequest("secret item id is required")
        }
        assert(!itemID.isEmpty, "guard rejects an empty id")
        return itemID
    }

    private func secretBody(_ request: AuthBridgeRequest) -> SecretBridgeRequest {
        assert(request.surface == .secrets, "secret bodies belong to the secrets surface")
        guard case .secret(let body) = request.req else {
            return SecretBridgeRequest(
                itemID: nil, label: nil, attributes: nil, secretBase64: nil)
        }
        return body
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension AuthProxyError {
    var wireCode: AuthErrorCode {
        switch self {
        case .badRequest: return .badRequest
        case .denied: return .denied
        case .notFound: return .notFound
        case .locked: return .locked
        case .unavailable: return .hostUnavailable
        case .tooLarge: return .tooLarge
        case .timedOut: return .timeout
        case .io: return .hostUnavailable
        case .backend: return .internal
        }
    }

    var wireMessage: String {
        switch self {
        case .badRequest(let message), .denied(let message), .io(let message),
            .notFound(let message), .locked(let message), .timedOut(let message),
            .backend(let message):
            return message
        case .unavailable: return "host ssh-agent unavailable"
        case .tooLarge: return "ssh-agent packet too large"
        }
    }
}

/// Waits for the peer to start a request. A socket receive timeout cannot do
/// this on its own: it would also fire in the middle of an arriving frame.
enum AuthPoll {
    static func waitReadable(fd: Int32, seconds: Double) -> Bool {
        assert(fd >= 0, "poll requires a valid descriptor")
        assert(seconds > 0, "idle timeout must be positive")
        guard fd >= 0, seconds > 0 else { return false }
        let deadline = Date().addingTimeInterval(seconds)
        for _ in 0..<64 {  // bounded: only EINTR retries reach the next iteration
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(remaining * 1000))
            if ready > 0 { return true }
            if ready == 0 { return false }
            guard errno == EINTR else { return false }
        }
        return false
    }
}

extension DaemonCore {
    func installAuthBridge(host: any VMBackend) {
        let listener = AuthBridgeListener(
            sessions: authSessions, sshProxy: HostSSHAgentProxy(),
            secrets: KeychainSecretStore(
                url: config.home.secretsMetadataURL, bytes: SecurityKeychainBackend()),
            logger: { [weak self] message in self?.log(message) },
            beginActivity: { [weak self] in self?.markAuthActivity(begin: true) },
            endActivity: { [weak self] in self?.markAuthActivity(begin: false) },
            isDistroRunning: { [weak self] name in self?.isDistroUp(name) ?? false })
        guard host.setReverseListener(listener, port: Proto.authPort) else {
            log("warning: auth listener install failed")
            return
        }
        withLock { authListener = listener }
        log("auth bridge listening on vsock:\(Proto.authPort)")
    }

    func authStatus(name: String?) throws -> AuthStatusData {
        let resolved = try resolveName(name)
        let policy = try AuthPolicyStore(url: config.home.authPolicyURL).policy(for: resolved)
        let hostAgent = HostSSHAgentProxy().available
        let sshAgent = policy.sshAgent ?? hostAgent
        return AuthStatusData(
            distro: resolved,
            sshAgent: sshAgent,
            secrets: policy.secrets,
            sshAgentDetail: authSSHAgentDetail(
                policy: policy.sshAgent, hostAgent: hostAgent,
                forwarding: policy.sshAgentForwarding),
            sshAgentForwarding: policy.sshAgentForwarding,
            secretsDetail: authSecretsDetail(enabled: policy.secrets))
    }

    /// Only session-bind declares forwarding on the wire; older and non-OpenSSH
    /// forwarding paths stay invisible to the host, and the detail says so.
    private func authSSHAgentDetail(
        policy: Bool?, hostAgent: Bool, forwarding: AuthForwardingPolicy
    ) -> String? {
        if policy == false { return "disabled by policy" }
        if !hostAgent { return "host SSH_AUTH_SOCK is unavailable" }
        let unenforced = "other forwarding paths are not detectable"
        if forwarding == .ask {
            return "forwarding prompts unavailable, treating ask as off; "
                + "session-bind forwarding is rejected, \(unenforced)"
        }
        if forwarding == .off {
            return "OpenSSH session-bind forwarding is rejected; \(unenforced)"
        }
        return nil
    }

    private func authSecretsDetail(enabled: Bool) -> String? {
        enabled ? nil : "disabled by policy"
    }

    func isDistroUp(_ name: String) -> Bool {
        assert(!name.isEmpty, "distro name must not be empty")
        guard !name.isEmpty else { return false }
        return withLock { running && distrosUp.contains(name) }
    }

    private func markAuthActivity(begin: Bool) {
        if begin { beginOp() } else { endOp() }
        withLock { lastActivity = Date() }
    }
}
