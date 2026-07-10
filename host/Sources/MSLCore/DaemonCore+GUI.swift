import Foundation

/// Per-`(distro, user)` GUI runtime bookkeeping: the guest compositor facts the
/// daemon caches, the single-use attach tokens it mints, and the presenter/app
/// counts that pin the VM against idle reclaim. Pure value type mutated under
/// `DaemonCore`'s lock so the hold arithmetic is unit-testable without a VM.
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
        var windows: Int = 0
        var lastError: String?
        var graceUntil: Date
        var mints: [Mint] = []
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
    /// is removed here, so a replay of the same token is rejected.
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
        records[key] = record
    }

    /// A presenter relay ended: drop it and reopen the bounded reconnect window.
    mutating func presenterFinished(key: Key, graceUntil: Date) {
        guard var record = records[key] else { return }
        assert(record.presenters >= 0, "presenter count is never negative")
        record.presenters = max(0, record.presenters - 1)
        if record.presenters == 0 { record.graceUntil = graceUntil }
        records[key] = record
    }

    /// Count one msl-launched GUI app against the runtime; saturates at the cap.
    mutating func addWindow(key: Key) {
        guard var record = records[key], record.windows < Self.maxWindows else { return }
        record.windows += 1
        records[key] = record
        assert(records[key]?.windows ?? 0 <= Self.maxWindows, "window count stays bounded")
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

    /// Runtimes that pin the VM: a connected presenter, a live app, or an open
    /// reconnect window. The idle policy refuses to stop while any of these hold.
    func holdCount(now: Date) -> Int {
        return records.values.reduce(0) { total, record in
            let held = record.presenters > 0 || record.windows > 0 || now < record.graceUntil
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
                presenters: record.presenters, windows: record.windows, lastError: record.lastError)
        }.sorted { $0.distro == $1.distro ? $0.user < $1.user : $0.distro < $1.distro }
    }
}

extension DaemonCore {
    public func guiProbe(_ req: GuiRuntimeReq) throws -> GuiProbeData {
        beginOp()
        defer { endOp() }
        let target = try guiTarget(req)
        return try target.control.guiProbe(target.runtime)
    }

    public func guiStart(_ req: GuiRuntimeReq) throws -> GuiRuntimeData {
        beginOp()
        defer { endOp() }
        return try prepareGuiRuntime(distro: req.distro, user: req.user).runtime
    }

    public func guiStatus(_ req: GuiRuntimeReq) throws -> GuiRuntimeData {
        beginOp()
        defer { endOp() }
        let target = try guiTarget(req)
        return try target.control.guiStatus(target.runtime)
    }

    public func guiStop(_ req: GuiRuntimeReq) throws -> GuiRuntimeData {
        beginOp()
        defer { endOp() }
        let target = try guiTarget(req)
        let key = GuiRuntimeTable.Key(distro: target.runtime.distro, user: target.runtime.user)
        defer { withLock { _ = guiRuntimes.remove(key: key) } }
        return try target.control.guiStop(target.runtime)
    }

    public func guiLaunch(_ req: GuiLaunchReq) throws -> ExecData {
        beginOp()
        defer { endOp() }
        let entry = try ensureUp(req.distro)
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        let launch = GuiLaunchReq(
            distro: entry.name, user: req.user, argv: req.argv, env: req.env, cwd: req.cwd)
        let data = try control.guiLaunch(launch)
        guard data.exitCode == 0 else { return data }
        let key = GuiRuntimeTable.Key(distro: entry.name, user: req.user)
        withLock {
            guiRuntimes.addWindow(key: key)
            lastActivity = Date()
        }
        return data
    }

    /// Prepare the runtime if needed and mint a single-use attach token bound to
    /// `(distro, user)`. The presenter must present it to reach the surface plane.
    public func guiToken(name: String?, user: String?) throws -> GuiTokenData {
        beginOp()
        defer { endOp() }
        let prepared = try prepareGuiRuntime(distro: try resolveName(name), user: user)
        let token = Token.generate()
        let now = Date()
        let expires = now.addingTimeInterval(guiAttachDeadline)
        try withLockThrowing {
            try guiRuntimes.mint(key: prepared.key, token: token, expires: expires, now: now)
            lastActivity = now
        }
        return GuiTokenData(
            distro: prepared.key.distro, user: prepared.key.requestedUser, token: token,
            expiresInS: Int(guiAttachDeadline))
    }

    /// Consume the attach token and open the guest surface plane (vsock 5020).
    /// The raw fd is relayed to the presenter; `endGuiAttach` must balance this.
    public func beginGuiAttach(distro: String, user: String?, token: String) throws -> Int32 {
        guard !distro.isEmpty, !token.isEmpty else {
            throw MSLError.protocolMismatch("GUI attach needs a distro and a token")
        }
        let key = GuiRuntimeTable.Key(distro: distro, user: user)
        try withLockThrowing {
            try guiRuntimes.consume(key: key, token: token, now: Date())
            lastActivity = Date()
        }
        guard let host = withLock({ self.host }) else {
            releaseGuiPresenter(key)
            throw MSLError.configuration("VM not running")
        }
        do {
            let fd = try host.connectRaw(port: GuiProto.port, timeout: min(config.bootTimeout, 5))
            assert(fd >= 0, "connectRaw returns a valid fd or throws")
            return fd
        } catch {
            releaseGuiPresenter(key)
            throw error
        }
    }

    /// Balance a successful `beginGuiAttach` when its relay ends; the runtime
    /// keeps running for the bounded reconnect window.
    public func endGuiAttach(distro: String, user: String?) {
        assert(!distro.isEmpty, "GUI attach distro must not be empty")
        releaseGuiPresenter(GuiRuntimeTable.Key(distro: distro, user: user))
    }

    /// Stop and forget every GUI runtime for `distro` (nil = all). Stopping the
    /// guest compositor drops the surface-plane socket, which ends any presenter
    /// relay without the daemon ever owning a presenter fd.
    func teardownGui(distro: String?) {
        assert(distro.map { !$0.isEmpty } ?? true, "distro filter must not be empty")
        let keys = withLock { guiRuntimes.keys(distro: distro) }
        guard !keys.isEmpty else { return }
        let control = withLock { self.control }
        for key in keys {  // bounded: GuiRuntimeTable.maxRuntimes
            let req = GuiRuntimeReq(distro: key.distro, user: key.requestedUser)
            _ = try? control?.guiStop(req)
            withLock { _ = guiRuntimes.remove(key: key) }
        }
        withLock { lastActivity = Date() }
    }

    /// Reclaim runtimes whose presenter reconnect window closed. Runs on the idle
    /// tick, never on the lifecycle queue.
    func reapExpiredGuiRuntimes(now: Date) {
        let expired = withLock { guiRuntimes.expired(now: now) }
        guard !expired.isEmpty else { return }
        let control = withLock { self.control }
        for key in expired {  // bounded: GuiRuntimeTable.maxRuntimes
            log("stopping GUI runtime \(key.label): no presenter within the reconnect window")
            _ = try? control?.guiStop(GuiRuntimeReq(distro: key.distro, user: key.requestedUser))
            withLock { _ = guiRuntimes.remove(key: key) }
        }
    }

    func guiHoldCount(now: Date) -> Int {
        return guiRuntimes.holdCount(now: now)
    }

    private func releaseGuiPresenter(_ key: GuiRuntimeTable.Key) {
        assert(!key.distro.isEmpty, "GUI runtime key must name a distro")
        let grace = Date().addingTimeInterval(guiPresenterGrace)
        withLock {
            guiRuntimes.presenterFinished(key: key, graceUntil: grace)
            lastActivity = Date()
        }
    }

    private struct PreparedGui {
        let key: GuiRuntimeTable.Key
        let runtime: GuiRuntimeData
    }

    /// Ensure the distro is up and its GUI runtime is started and cached. Idempotent:
    /// an already-running runtime is refreshed, never restarted under live apps.
    private func prepareGuiRuntime(distro: String, user: String?) throws -> PreparedGui {
        let target = try guiTarget(GuiRuntimeReq(distro: distro, user: user))
        let key = GuiRuntimeTable.Key(distro: target.runtime.distro, user: target.runtime.user)
        let data = try target.control.guiStart(target.runtime)
        guard data.state == "running" else {
            withLock { guiRuntimes.fail(key: key, error: guiFailure(data)) }
            throw MSLError.configuration("GUI runtime for \(key.label) failed: \(guiFailure(data))")
        }
        let grace = Date().addingTimeInterval(guiPresenterGrace)
        try withLockThrowing { try guiRuntimes.prepare(key: key, runtime: data, graceUntil: grace) }
        return PreparedGui(key: key, runtime: data)
    }

    private func guiFailure(_ data: GuiRuntimeData) -> String {
        let tail = data.logTail.isEmpty ? data.state : data.logTail
        assert(!tail.isEmpty, "failure diagnostic must not be empty")
        return String(tail.suffix(512))
    }

    private struct GuiTarget {
        let control: ControlClient
        let runtime: GuiRuntimeReq
    }

    private func guiTarget(_ req: GuiRuntimeReq) throws -> GuiTarget {
        let entry = try ensureUp(req.distro)
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        let runtime = GuiRuntimeReq(distro: entry.name, user: req.user)
        return GuiTarget(control: control, runtime: runtime)
    }
}
