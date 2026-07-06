import Foundation

/// FSKit file-service transport constants (ADR 0009, docs/specs/fskit-finder.md)
/// shared by the daemon and the sandboxed appex; the binary wire codec types
/// nest under this enum too (FSProtoTypes/Codec/Frames). This module carries no
/// Virtualization dependency so the appex can link it without pulling in the VMM.
public enum FSProto {
    /// File-service protocol version, independent of the guest control protocol.
    public static let version = 2

    /// Daemon <-> guest file-service vsock port, one connection per volume.
    public static let vsockPort: UInt32 = 5030

    /// Basename of the appex-admission socket inside the app-group container.
    public static let appexSocketName = "msl-fskit.sock"

    /// The msl app group, appex bundle id, FSKit short name, and URL scheme.
    public static let appGroupID = "group.dev.msl.app"
    public static let appexBundleID = "dev.msl.app.fsmodule"
    public static let shortName = "mslfs"
    public static let scheme = "msl"

    /// Single `read` reply cap.
    public static let readReplyCap = 1 * 1024 * 1024

    /// Single `write` request data cap.
    public static let writeRequestCap = 1 * 1024 * 1024

    /// JSON control-frame (hello/reply) ceiling, matching the byte splice's
    /// 4 MiB frame cap; the daemon relays raw bytes after the hello/reply.
    public static let frameMax = 4 * 1024 * 1024

    /// Appex-admission socket path inside the app-group container. The daemon
    /// resolves it from home; the sandboxed appex uses the group-container API.
    public static func appexSocketPath(home: String = NSHomeDirectory()) -> String {
        precondition(!home.isEmpty, "home directory must not be empty")
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(appGroupID)
            .appendingPathComponent(appexSocketName).path
    }

    /// Control-frame (hello/reply) encode or decode failure.
    public enum FrameError: Error, Sendable, Equatable {
        case oversize(Int)
        case malformed(String)
    }
}
