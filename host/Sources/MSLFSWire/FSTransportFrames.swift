import Foundation

/// The appex's first control frame. Routing data only — never an authorization
/// secret; the daemon authenticates the peer and consumes the single-use nonce.
public struct FSHello: Codable, Equatable, Sendable {
    public let version: Int
    public let op: String
    public let distro: String
    public let mountID: String
    public let nonce: String
    public let readonly: Bool

    enum CodingKeys: String, CodingKey {
        case op, distro, nonce, readonly
        case version = "v"
        case mountID = "mount_id"
    }

    public init(distro: String, mountID: String, nonce: String, readonly: Bool = true) {
        precondition(!distro.isEmpty, "hello distro must not be empty")
        self.version = FSProto.version
        self.op = "hello"
        self.distro = distro
        self.mountID = mountID
        self.nonce = nonce
        self.readonly = readonly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.op = try container.decode(String.self, forKey: .op)
        self.distro = try container.decode(String.self, forKey: .distro)
        self.mountID = try container.decode(String.self, forKey: .mountID)
        self.nonce = try container.decode(String.self, forKey: .nonce)
        self.readonly = try container.decodeIfPresent(Bool.self, forKey: .readonly) ?? true
    }

    /// Encode to a framed JSON payload, enforcing the shared frame bound.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= FSProto.frameMax else {
            throw FSProto.FrameError.oversize(data.count)
        }
        return data
    }

    /// Decode and validate one framed hello: correct op, version, non-empty ids.
    public static func decode(_ bytes: Data) throws -> FSHello {
        guard !bytes.isEmpty else { throw FSProto.FrameError.malformed("empty fs hello") }
        let hello = try JSONDecoder().decode(FSHello.self, from: bytes)
        guard hello.op == "hello" else {
            throw FSProto.FrameError.malformed("first fs frame must be hello, got \(hello.op)")
        }
        guard hello.version == FSProto.version else {
            throw FSProto.FrameError.malformed("fs protocol \(hello.version) != \(FSProto.version)")
        }
        guard !hello.distro.isEmpty, !hello.mountID.isEmpty, !hello.nonce.isEmpty else {
            throw FSProto.FrameError.malformed("fs hello missing distro/mount_id/nonce")
        }
        return hello
    }
}

/// Daemon's control reply to the hello, before the stream goes raw.
public struct FSControlReply: Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }

    public func encoded() throws -> Data {
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ bytes: Data) throws -> FSControlReply {
        guard !bytes.isEmpty else { throw FSProto.FrameError.malformed("empty fs control reply") }
        return try JSONDecoder().decode(FSControlReply.self, from: bytes)
    }
}
