import Foundation

/// Per-`(distro, user)` GUI runtime bookkeeping: the guest compositor facts the
/// daemon caches, the single-use attach tokens it mints, the presenter-starting
/// lease that serializes spawns, and the presenter/launched-app counts that pin
/// the VM against idle reclaim. Pure value type mutated under `DaemonCore`'s lock
/// so the hold arithmetic is unit-testable without a VM.
public struct GuiRuntimeTable: Sendable, Equatable {
    public static let maxRuntimes = 8
    public static let maxPresenters = 8
    public static let maxWindows = 256
    public static let maxTokens = 8

    /// Runtime identity. An empty `user` means the distro's default user.
    public struct Key: Hashable, Sendable {
        public let distro: String
        public let user: String

        public init(distro: String, user: String?) {
            precondition(!distro.isEmpty, "GUI runtime distro must not be empty")
            precondition(user.map { !$0.isEmpty } ?? true, "GUI runtime user must not be empty")
            self.distro = distro
            self.user = user ?? ""
        }

        public var requestedUser: String? { user.isEmpty ? nil : user }
        public var displayUser: String { user.isEmpty ? "default" : user }
        public var label: String { "\(distro)/\(displayUser)" }
    }

    /// Spawn-serialization state for the runtime's one presenter. `.starting`
    /// carries the deadline by which the spawned presenter must attach; a launch
    /// that finds an expired `.starting` treats it as `.idle` and may respawn.
    enum PresenterLease: Sendable, Equatable {
        case idle
        case starting(deadline: Date)
        case attached
    }

    struct Mint: Sendable, Equatable {
        let value: String
        let expires: Date
    }

    struct Record: Sendable, Equatable {
        var state: String
        var pid: UInt32?
        var waylandDisplay: String
        var x11Display: String?
        var presenters: Int = 0
        /// Count of msl-launched GUI app processes. Reported in status; it does
        /// not itself pin the VM (the presenter/lease/grace terms do), so a stale
        /// value can never leak the VM. Reset when the presenting session ends.
        var launchedProcesses: Int = 0
        var lastError: String?
        var graceUntil: Date
        var mints: [Mint] = []
        var presenterLease: PresenterLease = .idle
    }

    private var records: [Key: Record] = [:]

    public init() {}

    public var count: Int { records.count }

    func isRunning(_ key: Key) -> Bool { records[key]?.state == "running" }

    /// Cache a prepared runtime (idempotent). `graceUntil` opens the reconnect
    /// window a presenter has to arrive in before the runtime is reclaimed.
    mutating func prepare(key: Key, runtime: GuiRuntimeData, graceUntil: Date) throws {
        guard !runtime.state.isEmpty else {
            throw MSLError.protocolMismatch("guest returned an empty GUI runtime state")
        }
        guard records[key] != nil || records.count < Self.maxRuntimes else {
            throw MSLError.configuration("too many GUI runtimes (max \(Self.maxRuntimes))")
        }
        if var record = records[key] {
            record.state = runtime.state
            record.pid = runtime.pid
            record.waylandDisplay = runtime.waylandDisplay
            records[key] = record
            return
        }
        records[key] = Record(
            state: runtime.state, pid: runtime.pid, waylandDisplay: runtime.waylandDisplay,
            x11Display: nil, lastError: nil, graceUntil: graceUntil)
    }

    /// Mint one bounded-lifetime attach token; only a prepared, running runtime
    /// can hand one out, which is what makes a raw untokenized attach impossible.
    mutating func mint(key: Key, token: String, expires: Date, now: Date) throws {
        guard !token.isEmpty, expires > now else {
            throw MSLError.configuration("GUI attach token must be non-empty and future-dated")
        }
        guard var record = records[key], record.state == "running" else {
            throw MSLError.configuration("no prepared GUI runtime for \(key.label)")
        }
        record.mints.removeAll { $0.expires <= now }
        guard record.mints.count < Self.maxTokens else {
            throw MSLError.configuration("too many pending GUI attach tokens for \(key.label)")
        }
        record.mints.append(Mint(value: token, expires: expires))
        records[key] = record
    }

    /// Consume a token and register the presenter. Single-use: the matching mint
    /// is removed here, so a replay of the same token is rejected. Attaching
    /// settles the presenter-starting lease into `.attached`.
    mutating func consume(key: Key, token: String, now: Date) throws {
        guard !token.isEmpty else {
            throw MSLError.protocolMismatch("empty GUI attach token")
        }
        guard var record = records[key], record.state == "running" else {
            throw MSLError.configuration("no prepared GUI runtime for \(key.label)")
        }
        record.mints.removeAll { $0.expires <= now }
        guard let index = record.mints.firstIndex(where: { Token.matches($0.value, token) }) else {
            throw MSLError.protocolMismatch("GUI attach token rejected for \(key.label)")
        }
        guard record.presenters < Self.maxPresenters else {
            throw MSLError.configuration("too many GUI presenters for \(key.label)")
        }
        record.mints.remove(at: index)
        record.presenters += 1
        record.presenterLease = .attached
        records[key] = record
    }

    /// A presenter relay ended: drop it and reopen the bounded reconnect window.
    /// The last presenter leaving ends the presenting session, so the lease
    /// returns to `.idle` and the launched-app count is drained — the host has no
    /// per-app exit signal, so session end is the coarsest boundary it observes.
    mutating func presenterFinished(key: Key, graceUntil: Date) {
        guard var record = records[key] else { return }
        assert(record.presenters >= 0, "presenter count is never negative")
        record.presenters = max(0, record.presenters - 1)
        if record.presenters == 0 {
            record.graceUntil = graceUntil
            record.launchedProcesses = 0
            record.presenterLease = .idle
        }
        records[key] = record
    }

    /// Atomically decide whether this launch spawns the presenter and, if so,
    /// mint its attach token and move the lease to `.starting`. Returns false when
    /// a presenter is attached or an unexpired `.starting` lease is already live,
    /// so two concurrent launches can never spawn two presenters. Caller runs this
    /// under the same lock that guards the presenter count.
    mutating func beginPresenterSpawn(key: Key, token: String, deadline: Date, now: Date) -> Bool {
        precondition(!token.isEmpty, "presenter token must not be empty")
        precondition(deadline > now, "presenter lease must be future-dated")
        guard var record = records[key], record.state == "running", record.presenters == 0 else {
            return false
        }
        if case .attached = record.presenterLease { return false }
        if case .starting(let live) = record.presenterLease, now < live { return false }
        record.mints.removeAll { $0.expires <= now }
        guard record.mints.count < Self.maxTokens else { return false }
        record.mints.append(Mint(value: token, expires: deadline))
        record.presenterLease = .starting(deadline: deadline)
        records[key] = record
        assert(records[key]?.mints.count ?? 0 <= Self.maxTokens, "token set stays bounded")
        return true
    }

    /// Undo a `beginPresenterSpawn` whose spawn failed before the presenter could
    /// attach: drop the unused token and return the lease to `.idle` so a later
    /// launch may retry without waiting out the lease deadline.
    mutating func abortPresenterSpawn(key: Key, token: String) {
        guard var record = records[key] else { return }
        record.mints.removeAll { Token.matches($0.value, token) }
        if case .starting = record.presenterLease { record.presenterLease = .idle }
        records[key] = record
    }

    /// Count one msl-launched GUI app against the runtime; saturates at the cap.
    mutating func noteLaunchedProcess(key: Key) {
        guard var record = records[key], record.launchedProcesses < Self.maxWindows else { return }
        record.launchedProcesses += 1
        records[key] = record
        assert((records[key]?.launchedProcesses ?? 0) <= Self.maxWindows, "launch count bounded")
    }

    mutating func fail(key: Key, error: String) {
        guard var record = records[key], !error.isEmpty else { return }
        record.state = "failed"
        record.lastError = error
        records[key] = record
    }

    @discardableResult
    mutating func remove(key: Key) -> Bool {
        return records.removeValue(forKey: key) != nil
    }

    mutating func removeAll() { records.removeAll() }

    /// Keys for one distro, or every key when `distro` is nil. Sorted so teardown
    /// order is deterministic.
    func keys(distro: String?) -> [Key] {
        assert(distro.map { !$0.isEmpty } ?? true, "distro filter must not be empty")
        return records.keys.filter { distro == nil || $0.distro == distro }
            .sorted { $0.label < $1.label }
    }

    /// Runtimes that pin the VM: a connected presenter, a presenter still inside
    /// its spawn lease, or an open reconnect window. Every term is bounded, so the
    /// hold is always reclaimable — the launched-app count deliberately does not
    /// appear here (see `Record.launchedProcesses`).
    func holdCount(now: Date) -> Int {
        return records.values.reduce(0) { total, record in
            var leaseLive = false
            if case .starting(let deadline) = record.presenterLease { leaseLive = now < deadline }
            let held = record.presenters > 0 || now < record.graceUntil || leaseLive
            return total + (held ? 1 : 0)
        }
    }

    /// Runtimes whose reconnect window closed with no presenter attached: their
    /// apps have outlived the bounded window and the runtime may be stopped.
    func expired(now: Date) -> [Key] {
        return records.compactMap { key, record in
            guard record.presenters == 0, now >= record.graceUntil else { return nil }
            return key
        }.sorted { $0.label < $1.label }
    }

    func statuses() -> [GuiRuntimeStatus] {
        return records.map { key, record in
            GuiRuntimeStatus(
                distro: key.distro, user: key.displayUser, state: record.state, pid: record.pid,
                waylandDisplay: record.waylandDisplay, x11Display: record.x11Display,
                presenters: record.presenters, windows: record.launchedProcesses,
                lastError: record.lastError)
        }.sorted { $0.distro == $1.distro ? $0.user < $1.user : $0.distro < $1.distro }
    }
}
