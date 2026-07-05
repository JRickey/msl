import Foundation

/// Constants and control frames for the FSKit file-service transport (ADR 0009,
/// docs/specs/fskit-finder.md). The appex connects the app-group Unix-domain
/// socket and sends one `hello`; the daemon authenticates, then splices the hot
/// stream byte-for-byte to the guest vsock file-service channel.
public enum FSProto {
    /// File-service protocol version, independent of `Proto.version`.
    public static let version = 1

    /// Daemon <-> guest file-service vsock port, one connection per volume.
    public static let vsockPort: UInt32 = 5030

    /// Basename of the appex-admission socket inside the app-group container.
    public static let appexSocketName = "msl-fskit.sock"

    /// The msl app group, appex bundle id, FSKit short name, and URL scheme.
    public static let appGroupID = "group.dev.msl.app"
    public static let appexBundleID = "dev.msl.app.fsmodule"
    public static let shortName = "mslfs"
    public static let scheme = "msl"

    /// Single `read` reply cap in v0 (the frame cap stays `Proto.maxPayload`).
    public static let readReplyCap = 1 * 1024 * 1024

    /// Developer team (ADR 0009) whose leaf-cert OU the appex designated
    /// requirement pins. Overridable by `MSL_FSKIT_TEAM_ID` for other accounts.
    public static let defaultTeamID = "REDACTED_TEAM_ID"

    /// Appex-admission socket path inside the app-group container.
    public static func appexSocketPath(home: String = NSHomeDirectory()) -> String {
        precondition(!home.isEmpty, "home directory must not be empty")
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(appGroupID)
            .appendingPathComponent(appexSocketName).path
    }
}

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

    /// Encode to a framed JSON payload, enforcing the shared frame bound.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("fs hello \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
    }

    /// Decode and validate one framed hello: correct op, version, non-empty ids.
    public static func decode(_ bytes: Data) throws -> FSHello {
        guard !bytes.isEmpty else { throw MSLError.protocolMismatch("empty fs hello") }
        let hello = try JSONDecoder().decode(FSHello.self, from: bytes)
        guard hello.op == "hello" else {
            throw MSLError.protocolMismatch("first fs frame must be hello, got \(hello.op)")
        }
        guard hello.version == FSProto.version else {
            throw MSLError.protocolMismatch("fs protocol \(hello.version) != \(FSProto.version)")
        }
        guard !hello.distro.isEmpty, !hello.mountID.isEmpty, !hello.nonce.isEmpty else {
            throw MSLError.protocolMismatch("fs hello missing distro/mount_id/nonce")
        }
        return hello
    }
}

/// Daemon's first frame to the guest fs-service port (vsock 5030): names the
/// distro whose mount namespace the msl-fsd worker serves. Routing only — the
/// appex was already authenticated and its nonce consumed before this is sent.
public struct FSGuestOpen: Codable, Equatable, Sendable {
    public let version: Int
    public let op: String
    public let distro: String

    enum CodingKeys: String, CodingKey {
        case op, distro
        case version = "v"
    }

    public init(distro: String) {
        precondition(!distro.isEmpty, "fs_open distro must not be empty")
        self.version = FSProto.version
        self.op = "fs_open"
        self.distro = distro
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Proto.maxPayload else {
            throw MSLError.framing("fs_open \(data.count) exceeds \(Proto.maxPayload)")
        }
        return data
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
        guard !bytes.isEmpty else { throw MSLError.protocolMismatch("empty fs control reply") }
        return try JSONDecoder().decode(FSControlReply.self, from: bytes)
    }
}

/// Payload of the `mount_prepare` reply: the routing URL the CLI hands to
/// `/sbin/mount -F`, plus the mountpoint the CLI creates and mounts on. The
/// mount id and nonce are already embedded in `url`; they are echoed for logs.
public struct MountPrepareData: Sendable, Equatable, Codable {
    public let name: String
    public let url: String
    public let mountpoint: String
    public let mountID: String
    public let nonce: String

    enum CodingKeys: String, CodingKey {
        case name, url, mountpoint, nonce
        case mountID = "mount_id"
    }

    public init(name: String, url: String, mountpoint: String, mountID: String, nonce: String) {
        precondition(!name.isEmpty, "mount name must not be empty")
        precondition(!url.isEmpty, "mount url must not be empty")
        precondition(!mountpoint.isEmpty, "mountpoint must not be empty")
        self.name = name
        self.url = url
        self.mountpoint = mountpoint
        self.mountID = mountID
        self.nonce = nonce
    }
}

/// One mounted (or preparing) distro in the `mount_status` reply.
public struct MountEntry: Sendable, Equatable, Codable {
    public let name: String
    public let mountpoint: String
    public let state: String

    public init(name: String, mountpoint: String, state: String) {
        self.name = name
        self.mountpoint = mountpoint
        self.state = state
    }
}

/// Payload of the `mount_status` reply.
public struct MountStatusData: Sendable, Equatable, Codable {
    public let mounts: [MountEntry]

    public init(mounts: [MountEntry]) {
        self.mounts = mounts
    }
}
