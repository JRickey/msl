import Foundation

/// Live guest sessions the daemon has opened, keyed by guest session id. Pure
/// value type mutated under `DaemonCore`'s lock; the single-use attach-token
/// rule and per-distro session counts live here so both are unit-testable.
public struct SessionTable: Sendable, Equatable {
    /// One open session: the distro it belongs to, the guest data-plane token,
    /// the single-use local attach token (consumed on the first attach), whether
    /// a client has attached yet, and when it was opened (for the orphan reaper).
    public struct Record: Sendable, Equatable {
        public let name: String
        public let guestToken: String
        public let localToken: String
        public var tokenUsed: Bool
        public var attached: Bool
        public let openedAt: Date
        public var finished: Bool = false
        public var exitCode: Int32?
    }

    private var records: [UInt64: Record] = [:]

    public init() {}

    /// Total open sessions across all distros (attached or not).
    public var liveCount: Int { records.count }

    /// Register a freshly opened session. Rejects a duplicate id.
    public mutating func add(
        sessionID: UInt64, name: String, guestToken: String, localToken: String,
        openedAt: Date = Date()
    ) throws {
        precondition(!name.isEmpty, "session distro name must not be empty")
        precondition(!guestToken.isEmpty, "guest token must not be empty")
        guard records[sessionID] == nil else {
            throw MSLError.protocolMismatch("duplicate session id: \(sessionID)")
        }
        records[sessionID] = Record(
            name: name, guestToken: guestToken, localToken: localToken, tokenUsed: false,
            attached: false, openedAt: openedAt)
    }

    /// Consume the single-use local token for an attach; marks the session
    /// attached and returns the record. Rejects reuse or a bad token.
    public mutating func consumeLocalToken(sessionID: UInt64, token: String) throws -> Record {
        guard var record = records[sessionID] else {
            throw MSLError.protocolMismatch("no such session: \(sessionID)")
        }
        guard !record.tokenUsed else {
            throw MSLError.protocolMismatch("attach token already used: \(sessionID)")
        }
        guard Token.matches(record.localToken, token) else {
            throw MSLError.protocolMismatch("attach token mismatch: \(sessionID)")
        }
        record.tokenUsed = true
        record.attached = true
        records[sessionID] = record
        return record
    }

    /// Ids of sessions a client never attached to within `deadline` seconds of
    /// opening; the idle tick reaps these so an abandoned open cannot pin the VM.
    public func expiredPending(now: Date, deadline: TimeInterval) -> [UInt64] {
        precondition(deadline > 0, "attach deadline must be positive")
        return records.compactMap { key, record in
            let stale = now.timeIntervalSince(record.openedAt) >= deadline
            guard stale, record.finished || !record.attached else { return nil }
            return key
        }
    }

    /// Sessions that count as live for idle purposes: attached ones plus pending
    /// ones still inside their attach deadline (expired pending ones are reaped).
    public func liveCountForIdle(now: Date, deadline: TimeInterval) -> Int {
        precondition(deadline > 0, "attach deadline must be positive")
        return records.values.reduce(0) { total, record in
            guard !record.finished else { return total }
            let live = record.attached || now.timeIntervalSince(record.openedAt) < deadline
            return total + (live ? 1 : 0)
        }
    }

    /// Cache a finished session's exit code until the client's wait consumes it.
    public mutating func markFinished(sessionID: UInt64, exitCode: Int32?) {
        guard var record = records[sessionID] else { return }
        record.finished = true
        record.exitCode = exitCode
        records[sessionID] = record
    }

    /// Consume a finished session: returns its cached exit code and removes it;
    /// nil when the session is absent or not finished yet.
    public mutating func consumeFinished(sessionID: UInt64) -> Int32?? {
        guard let record = records[sessionID], record.finished else { return nil }
        records.removeValue(forKey: sessionID)
        return .some(record.exitCode)
    }

    /// Look up a session's owning distro without mutating state.
    public func name(of sessionID: UInt64) -> String? {
        return records[sessionID]?.name
    }

    /// Remove a finished session; returns true when it was present.
    @discardableResult
    public mutating func remove(sessionID: UInt64) -> Bool {
        return records.removeValue(forKey: sessionID) != nil
    }

    /// Live session count for one distro (drives per-distro status).
    public func sessions(forName name: String) -> Int {
        precondition(!name.isEmpty, "distro name must not be empty")
        return records.values.reduce(0) { $0 + ($1.name == name ? 1 : 0) }
    }
}
