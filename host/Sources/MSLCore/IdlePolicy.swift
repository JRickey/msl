import Foundation

/// Pure idle-timeout arithmetic for the daemon's coarse timer. Kept separate so
/// the stop decision is unit-testable without a VM or a running clock.
public enum IdlePolicy {
    /// The VM should stop when: the timeout is enabled (> 0), no sessions are
    /// live, no GUI runtime holds it (live apps, connected presenters, or an open
    /// presenter-reconnect window), no lifecycle op is in flight, and the machine
    /// has been idle for `timeoutSeconds`. A timeout of 0 means "never stop".
    public static func shouldStop(
        now: Date, lastActivity: Date, liveSessions: Int, pendingOps: Int, guiHolds: Int = 0,
        timeoutSeconds: Int
    ) -> Bool {
        precondition(liveSessions >= 0, "live session count must be non-negative")
        precondition(pendingOps >= 0, "pending op count must be non-negative")
        precondition(guiHolds >= 0, "GUI hold count must be non-negative")
        guard timeoutSeconds > 0 else { return false }
        guard liveSessions == 0, pendingOps == 0, guiHolds == 0 else { return false }
        return now.timeIntervalSince(lastActivity) >= Double(timeoutSeconds)
    }
}
