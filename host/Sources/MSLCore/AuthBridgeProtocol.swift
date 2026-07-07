import Foundation

public enum AuthSurface: String, Codable, Sendable {
    case sshAgent = "ssh-agent"
    case secrets
}

public enum AuthErrorCode: String, Codable, Sendable {
    case badRequest = "bad_request"
    case unsupported
    case denied
    case notFound = "not_found"
    case locked
    case hostUnavailable = "host_unavailable"
    case timeout
    case tooLarge = "too_large"
    case `internal`
}

public struct AuthPeer: Codable, Equatable, Sendable {
    public let id: String
    public let token: String
    public let distro: String
    public let uid: UInt32?
    public let pid: UInt32?
    public let comm: String?
}

public struct AuthBridgeRequest: Codable, Equatable, Sendable {
    public let version: UInt32
    public let id: UInt64
    public let surface: AuthSurface
    public let session: AuthPeer
    public let op: String
    public let req: AuthPayload

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case id, surface, session, op, req
    }

    public static func decode(_ data: Data) throws -> AuthBridgeRequest {
        guard !data.isEmpty else { throw MSLError.protocolMismatch("empty auth request") }
        return try JSONDecoder().decode(AuthBridgeRequest.self, from: data)
    }
}

public enum AuthPayload: Codable, Equatable, Sendable {
    case sshForward(SSHForwardRequest)
    case query(AuthQueryRequest)
    case secret(SecretBridgeRequest)
    case empty

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let ssh = try? container.decode(SSHForwardRequest.self), ssh.packetBase64 != nil {
            self = .sshForward(ssh)
            return
        }
        if let query = try? container.decode(AuthQueryRequest.self), query.surface != nil {
            self = .query(query)
            return
        }
        if let secret = try? container.decode(SecretBridgeRequest.self), secret.hasPayload {
            self = .secret(secret)
            return
        }
        self = .empty
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .sshForward(let req): try container.encode(req)
        case .query(let req): try container.encode(req)
        case .secret(let req): try container.encode(req)
        case .empty: try container.encode([String: String]())
        }
    }
}

public struct SSHForwardRequest: Codable, Equatable, Sendable {
    public let packetBase64: String?

    enum CodingKeys: String, CodingKey {
        case packetBase64 = "packet_b64"
    }
}

public struct SSHForwardReply: Codable, Equatable, Sendable {
    public let packetBase64: String

    enum CodingKeys: String, CodingKey {
        case packetBase64 = "packet_b64"
    }
}

public struct AuthQueryRequest: Codable, Equatable, Sendable {
    public let surface: AuthSurface?
}

public struct AuthErrorBody: Codable, Equatable, Sendable {
    public let code: AuthErrorCode
    public let message: String
}

public struct AuthBridgeReply<Payload: Codable & Sendable>: Codable, Sendable {
    public let id: UInt64
    public let ok: Bool
    public let data: Payload?
    public let error: AuthErrorBody?

    public static func ok(id: UInt64, _ data: Payload) throws -> Data {
        return try JSONEncoder().encode(
            AuthBridgeReply(id: id, ok: true, data: data, error: nil))
    }
}

public enum AuthBridgeError {
    public static func frame(id: UInt64, code: AuthErrorCode, message: String) -> Data {
        assert(!message.isEmpty, "auth error message must not be empty")
        let reply = AuthBridgeReply<AuthEmpty>(
            id: id, ok: false, data: nil, error: AuthErrorBody(code: code, message: message))
        return (try? JSONEncoder().encode(reply)) ?? Data(#"{"id":0,"ok":false}"#.utf8)
    }
}

public struct AuthEmpty: Codable, Equatable, Sendable {}

public struct AuthQueryData: Codable, Equatable, Sendable {
    public let sshAgent: Bool
    public let secrets: Bool

    enum CodingKeys: String, CodingKey {
        case sshAgent = "ssh_agent"
        case secrets
    }
}

public struct SecretBridgeRequest: Codable, Equatable, Sendable {
    public let itemID: String?
    public let label: String?
    public let attributes: [String: String]?
    public let secretBase64: String?

    enum CodingKeys: String, CodingKey {
        case label, attributes
        case itemID = "item_id"
        case secretBase64 = "secret_b64"
    }

    var hasPayload: Bool {
        return itemID != nil || label != nil || attributes != nil || secretBase64 != nil
    }
}

public struct SecretCollectionData: Codable, Equatable, Sendable {
    public let collections: [String]
}

public struct SecretItemData: Codable, Equatable, Sendable {
    public let item: SecretItemSummary
    public let secretBase64: String?

    enum CodingKeys: String, CodingKey {
        case item
        case secretBase64 = "secret_b64"
    }
}

public struct SecretItemsData: Codable, Equatable, Sendable {
    public let items: [SecretItemSummary]
}

public struct SecretItemSummary: Codable, Equatable, Sendable {
    public let id: String
    public let collection: String
    public let label: String
    public let attributes: [String: String]
    public let created: UInt64
    public let modified: UInt64

    public init(_ record: SecretItemRecord) {
        id = record.id
        collection = record.collection
        label = record.label
        attributes = record.attributes
        created = record.created
        modified = record.modified
    }
}
