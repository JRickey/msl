import Foundation
import MSLFSWire

/// Daemon-side FSKit mount types not shared with the appex: the daemon->guest
/// `fs_open` frame and the local CLI<->daemon mount replies. The shared
/// transport constants (`FSProto`) and the appex hello/reply frames
/// (`FSHello`/`FSControlReply`) live in `MSLFSWire`.

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
