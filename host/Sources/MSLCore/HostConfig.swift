import Foundation

/// A virtiofs share request parsed from `--share <tag>=<hostpath>[:ro]`.
public struct ShareSpec: Sendable, Equatable {
    public let tag: String
    public let hostPath: String
    public let readOnly: Bool

    public init(tag: String, hostPath: String, readOnly: Bool) {
        self.tag = tag
        self.hostPath = hostPath
        self.readOnly = readOnly
    }

    /// Parse one `--share` value. Validates the tag shape; path existence is
    /// checked later at boot-spec construction (this stays pure and testable).
    public static func parse(_ raw: String) throws -> ShareSpec {
        guard !raw.isEmpty else { throw MSLError.invalidArgument("empty --share value") }
        guard let eq = raw.firstIndex(of: "=") else {
            throw MSLError.invalidArgument("--share must be tag=path[:ro]: \(raw)")
        }
        let tag = String(raw[raw.startIndex..<eq])
        var path = String(raw[raw.index(after: eq)...])
        var readOnly = false
        if path.hasSuffix(":ro") {
            readOnly = true
            path = String(path.dropLast(3))
        }
        guard isValidTag(tag) else {
            throw MSLError.invalidArgument("invalid share tag (^[a-z][a-z0-9]{0,15}$): \(tag)")
        }
        guard !path.isEmpty else { throw MSLError.invalidArgument("empty share path: \(raw)") }
        return ShareSpec(tag: tag, hostPath: path, readOnly: readOnly)
    }

    /// Tag rule from the protocol: lowercase, alnum tail, at most 16 chars.
    public static func isValidTag(_ tag: String) -> Bool {
        guard (1...16).contains(tag.count) else { return false }
        var isFirst = true
        for ch in tag.unicodeScalars {
            let lower = ("a"..."z").contains(ch)
            let digit = ("0"..."9").contains(ch)
            if isFirst {
                guard lower else { return false }
                isFirst = false
            } else {
                guard lower || digit else { return false }
            }
        }
        return true
    }
}

/// Map a host cwd to the guest session cwd per the protocol: a path under
/// `$HOME` becomes `/mnt/mac/<relative>` when the mac share is present;
/// otherwise the distro user's home (`/root` in M1).
public func mapSessionCwd(hostCwd: String, home: String, hasMacShare: Bool) -> String {
    let distroHome = "/root"
    guard hasMacShare, !home.isEmpty else { return distroHome }
    let base = home.hasSuffix("/") ? String(home.dropLast()) : home
    if hostCwd == base { return "/mnt/mac" }
    let prefix = base + "/"
    guard hostCwd.hasPrefix(prefix) else { return distroHome }
    let relative = String(hostCwd.dropFirst(prefix.count))
    return relative.isEmpty ? "/mnt/mac" : "/mnt/mac/" + relative
}
