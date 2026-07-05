import Foundation

/// Pure admission and reconciliation policy for the appex-admission socket.
/// Separated from the syscalls in `FSPeerCredentials` so the decision logic is
/// exercised directly in tests without a signed peer.
public enum FSAdmission {
    /// Admit an appex connection only when the kernel-attested peer euid matches
    /// the daemon's own uid AND the audit-token designated-requirement check
    /// passed. Neither alone is sufficient; URL secrecy is never trusted.
    public static func admit(peerUID: UInt32, daemonUID: UInt32, drPassed: Bool) -> Bool {
        return peerUID == daemonUID && drPassed
    }

    /// Pinned designated requirement for the appex: matching bundle identifier,
    /// Apple-issued anchor, and the developer team's leaf certificate OU.
    public static func requirement(bundleID: String, teamID: String) -> String {
        precondition(!bundleID.isEmpty, "bundle id must not be empty")
        precondition(!teamID.isEmpty, "team id must not be empty")
        return "identifier \"\(bundleID)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// On daemon startup, decide which discovered `mslfs` mountpoints to
    /// force-unmount: any not in `known` (in-memory state the daemon can adopt).
    /// A fresh daemon has no known mounts, so every stale mount is reclaimed —
    /// no crash may leave an indefinitely wedged Finder mount.
    public static func reconcile(discovered: [String], known: Set<String>) -> [String] {
        return discovered.filter { !known.contains($0) }.sorted()
    }
}
