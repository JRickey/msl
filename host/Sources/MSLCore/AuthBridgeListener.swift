import Darwin
import Foundation
import Virtualization

final class AuthBridgeListener: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private let sessions: AuthSessionTable
    private let sshProxy: HostSSHAgentProxy
    private let secrets: KeychainSecretStore<SecurityKeychainBackend>
    private let logger: @Sendable (String) -> Void
    private let beginActivity: @Sendable () -> Void
    private let endActivity: @Sendable () -> Void
    private let lock = NSLock()
    private var live = 0
    private var accepting = true

    static let maxConnections = 32

    init(
        sessions: AuthSessionTable, sshProxy: HostSSHAgentProxy,
        secrets: KeychainSecretStore<SecurityKeychainBackend>,
        logger: @escaping @Sendable (String) -> Void,
        beginActivity: @escaping @Sendable () -> Void,
        endActivity: @escaping @Sendable () -> Void
    ) {
        self.sessions = sessions
        self.sshProxy = sshProxy
        self.secrets = secrets
        self.logger = logger
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        super.init()
    }

    func stop() {
        withLock { accepting = false }
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let raw = Darwin.dup(connection.fileDescriptor)
        connection.close()
        guard raw >= 0 else {
            logger("auth: dup failed errno=\(errno)")
            return false
        }
        guard admit() else {
            _ = Darwin.close(raw)
            return false
        }
        Thread.detachNewThread { [self] in
            serve(fd: raw)
            withLock { live = max(0, live - 1) }
        }
        return true
    }

    private func admit() -> Bool {
        return withLock {
            guard accepting, live < Self.maxConnections else { return false }
            live += 1
            return true
        }
    }

    private func serve(fd: Int32) {
        beginActivity()
        defer { endActivity() }
        guard let framed = try? VsockClient(fileDescriptor: fd) else {
            _ = Darwin.close(fd)
            return
        }
        defer { framed.close() }
        for _ in 0..<Int.max {
            guard let data = try? framed.receive() else { return }
            let reply = handle(data)
            guard (try? framed.send(reply)) != nil else { return }
        }
    }

    private func handle(_ data: Data) -> Data {
        let request: AuthBridgeRequest
        let session: AuthSession
        do {
            request = try AuthBridgeRequest.decode(data)
            guard request.version == 1 else {
                throw AuthValidationError(code: .badRequest, message: "bad auth version")
            }
            session = try sessions.validate(request.session, surface: request.surface)
        } catch let error as AuthValidationError {
            return AuthBridgeError.frame(id: 0, code: error.code, message: error.message)
        } catch {
            return AuthBridgeError.frame(id: 0, code: .badRequest, message: "bad auth request")
        }
        do {
            return try dispatch(request, session: session)
        } catch let error as AuthProxyError {
            return AuthBridgeError.frame(id: request.id, code: map(error), message: describe(error))
        } catch {
            return AuthBridgeError.frame(
                id: request.id, code: .internal, message: "auth bridge failed")
        }
    }

    private func dispatch(_ request: AuthBridgeRequest, session: AuthSession) throws -> Data {
        switch request.surface {
        case .sshAgent:
            return try dispatchSSH(request, session: session)
        case .secrets:
            return try dispatchSecrets(request, session: session)
        }
    }

    private func dispatchSSH(_ request: AuthBridgeRequest, session: AuthSession) throws -> Data {
        switch (request.op, request.req) {
        case ("ssh.forward_packet", .sshForward(let body)):
            guard let encoded = body.packetBase64, let packet = Data(base64Encoded: encoded)
            else { throw AuthProxyError.badRequest("bad packet encoding") }
            let reply = try sshProxy.forward(packet: packet)
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
        switch (request.op, request.req) {
        case ("secret.query", _):
            let data = AuthQueryData(sshAgent: session.sshAgent, secrets: session.secrets)
            return try AuthBridgeReply.ok(id: request.id, data)
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
            guard let id = body.itemID, !id.isEmpty else {
                throw AuthProxyError.badRequest("secret item id is required")
            }
            try secrets.delete(id: id)
            return try AuthBridgeReply.ok(id: request.id, AuthEmpty())
        case ("secret.item.properties", .secret(let body)):
            return try secretProperties(request.id, body)
        default:
            throw AuthProxyError.denied("unsupported auth operation")
        }
    }

    private func createSecret(_ id: UInt64, _ body: SecretBridgeRequest) throws -> Data {
        guard let encoded = body.secretBase64, let secret = Data(base64Encoded: encoded)
        else { throw AuthProxyError.badRequest("secret bytes are required") }
        let record = try secrets.create(
            label: body.label ?? "", attributes: body.attributes ?? [:], secret: secret)
        let data = SecretItemData(item: SecretItemSummary(record), secretBase64: nil)
        return try AuthBridgeReply.ok(id: id, data)
    }

    private func readSecret(_ id: UInt64, _ body: SecretBridgeRequest) throws -> Data {
        let record = try secretRecord(body)
        let secret = try secrets.secret(id: record.id)
        let data = SecretItemData(
            item: SecretItemSummary(record), secretBase64: secret.base64EncodedString())
        return try AuthBridgeReply.ok(id: id, data)
    }

    private func updateSecret(_ id: UInt64, _ body: SecretBridgeRequest) throws -> Data {
        guard let encoded = body.secretBase64, let secret = Data(base64Encoded: encoded)
        else { throw AuthProxyError.badRequest("secret bytes are required") }
        guard let itemID = body.itemID, !itemID.isEmpty else {
            throw AuthProxyError.badRequest("secret item id is required")
        }
        let record = try secrets.update(id: itemID, secret: secret)
        let data = SecretItemData(item: SecretItemSummary(record), secretBase64: nil)
        return try AuthBridgeReply.ok(id: id, data)
    }

    private func secretProperties(_ id: UInt64, _ body: SecretBridgeRequest) throws -> Data {
        let record = try secretRecord(body)
        let data = SecretItemData(item: SecretItemSummary(record), secretBase64: nil)
        return try AuthBridgeReply.ok(id: id, data)
    }

    private func secretRecord(_ body: SecretBridgeRequest) throws -> SecretItemRecord {
        guard let itemID = body.itemID, !itemID.isEmpty else {
            throw AuthProxyError.badRequest("secret item id is required")
        }
        let found = try secrets.search(attributes: [:])
        guard let record = found.first(where: { $0.id == itemID }) else {
            throw AuthProxyError.denied("secret item not found")
        }
        return record
    }

    private func secretBody(_ request: AuthBridgeRequest) -> SecretBridgeRequest {
        guard case .secret(let body) = request.req else {
            return SecretBridgeRequest(
                itemID: nil, label: nil, attributes: nil, secretBase64: nil)
        }
        return body
    }

    private func map(_ error: AuthProxyError) -> AuthErrorCode {
        switch error {
        case .badRequest: return .badRequest
        case .denied: return .denied
        case .unavailable: return .hostUnavailable
        case .tooLarge: return .tooLarge
        case .io: return .hostUnavailable
        }
    }

    private func describe(_ error: AuthProxyError) -> String {
        switch error {
        case .badRequest(let message), .denied(let message), .io(let message):
            return message
        case .unavailable: return "host ssh-agent unavailable"
        case .tooLarge: return "ssh-agent packet too large"
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension DaemonCore {
    func installAuthBridge(host: VMHost) {
        let listener = AuthBridgeListener(
            sessions: authSessions, sshProxy: HostSSHAgentProxy(),
            secrets: KeychainSecretStore(
                url: config.home.secretsMetadataURL, bytes: SecurityKeychainBackend()),
            logger: { [weak self] message in self?.log(message) },
            beginActivity: { [weak self] in self?.markAuthActivity(begin: true) },
            endActivity: { [weak self] in self?.markAuthActivity(begin: false) })
        guard host.setInteropListener(listener, port: Proto.authPort) else {
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

    private func authSSHAgentDetail(
        policy: Bool?, hostAgent: Bool, forwarding: AuthForwardingPolicy
    ) -> String? {
        if policy == false { return "disabled by policy" }
        if !hostAgent { return "host SSH_AUTH_SOCK is unavailable" }
        if forwarding == .ask { return "forwarding prompts unavailable; treating ask as off" }
        if forwarding == .off { return "OpenSSH session-bind forwarding is rejected" }
        return nil
    }

    private func authSecretsDetail(enabled: Bool) -> String? {
        enabled ? nil : "disabled by policy"
    }

    private func markAuthActivity(begin: Bool) {
        if begin { beginOp() } else { endOp() }
        withLock { lastActivity = Date() }
    }
}
