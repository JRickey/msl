import Darwin
import Foundation

/// The single-VM state machine behind one lock. Lifecycle transitions (boot,
/// distro up/down, stop) run on a serial queue so only one happens at a time
/// and no blocking I/O ever holds `stateLock`; `stateLock` guards only the
/// fast shared state (VM running flag, dev map, sessions, activity clock).
/// The lifecycle machinery lives in `DaemonCore+Lifecycle.swift`, so members it
/// shares are `internal` (module-scoped), not `private`.
public final class DaemonCore: @unchecked Sendable {
    let config: DaemonConfig
    private let stateLock = NSLock()
    let lifecycleQueue = DispatchQueue(label: "msl.daemon.lifecycle", qos: .userInitiated)
    private let idleQueue = DispatchQueue(label: "msl.daemon.idle", qos: .utility)
    let attachDeadline: TimeInterval = 30

    var running = false
    var host: VMHost?
    var control: ControlClient?
    var attached: [DeviceEntry] = []
    var distrosUp: Set<String> = []
    var rosettaAttached = false
    var sessions = SessionTable()
    var lastActivity = Date()
    var pendingOps = 0
    var powerWake: PowerWake?
    var forwarder: PortForwarder?
    var interopListener: InteropListener?
    var balloonTargetMiB: UInt64 = 0
    var comfortTicks = 0
    var reclaimedThisIdle = false
    var lastMemStats: MemStatsData?
    var pollTimer: DispatchSourceTimer?
    let pollQueue = DispatchQueue(label: "msl.daemon.poll", qos: .utility)
    private var idleTimer: DispatchSourceTimer?

    let mountTable = FSMountTable()
    var mountListener: FSMountListener?
    let mountInitLock = NSLock()

    public init(config: DaemonConfig) {
        self.config = config
    }

    /// Start the coarse idle timer (5s ticks). The daemon stays resident; only
    /// the VM is torn down when idle past the timeout.
    public func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: idleQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.idleTick() }
        timer.resume()
        idleTimer = timer
    }

    // MARK: - Control ops

    /// Snapshot of VM and distro state for `msl status` (queries the guest for
    /// authoritative per-distro states when the VM is running).
    public func status() throws -> StatusData {
        let registry = try Registry.load(from: config.home.registryURL)
        let snapshot = withLock { (running, attached, control) }
        guard snapshot.0, let control = snapshot.2 else {
            let distros = registry.distros.map {
                DistroStatus(name: $0.name, state: "stopped", sessions: 0)
            }
            return StatusData(vm: "stopped", distros: distros, idleTimeoutS: config.idleTimeoutS)
        }
        let guestStates = (try? control.distroList())?.distros ?? []
        return buildStatus(registry: registry, attached: snapshot.1, guestStates: guestStates)
    }

    /// Ensure the VM is booted and `name` (nil = registry default) is running.
    public func up(name: String?) throws {
        _ = try ensureUp(name)
    }

    /// Graceful distro down; `all` also stops the VM. A stopped VM is a no-op.
    /// Serialized on the lifecycle queue so it cannot interleave with boot/stop.
    public func down(name: String?, all: Bool, timeoutMs: UInt64?) throws {
        let resolved = all ? nil : try resolveName(name)
        try lifecycleQueue.sync {
            guard withLock({ running }) else { return }
            if all {
                performStop()
                return
            }
            guard let resolved, let control = withLock({ self.control }) else { return }
            unmountForDistroDown(resolved)
            _ = try control.distroDown(name: resolved, timeoutMs: timeoutMs ?? 15000)
            withLock {
                distrosUp.remove(resolved)
                lastActivity = Date()
            }
        }
    }

    /// Open a PTY session: ensure up, `session_open` on the guest, mint a local
    /// attach token, and register the session. Returns the id + local token.
    public func openShell(_ req: ShellRequest) throws -> ShellData {
        beginOp()
        defer { endOp() }
        let entry = try ensureUp(req.name)
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        let session = try resolveSession(
            name: entry.name, requested: req.argv, cwd: req.cwd ?? "/root")
        let open = SessionOpenReq(
            argv: session.argv, cwd: session.cwd, env: mergedEnv(req.env), rows: req.rows,
            cols: req.cols, distro: entry.name)
        let opened = try control.sessionOpen(open)
        let localToken = Token.generate()
        try withLockThrowing {
            try sessions.add(
                sessionID: opened.sessionID, name: entry.name, guestToken: opened.token,
                localToken: localToken)
            lastActivity = Date()
        }
        return ShellData(sessionID: opened.sessionID, token: localToken)
    }

    /// Consume the single-use attach token and open the guest data plane; the
    /// returned raw fd is relayed byte-for-byte to the client by the server. Any
    /// failure after the token is consumed reaps the session (no leak).
    public func beginAttach(sessionID: UInt64, token: String) throws -> Int32 {
        let record = try withLockThrowing { () -> SessionTable.Record in
            let rec = try sessions.consumeLocalToken(sessionID: sessionID, token: token)
            lastActivity = Date()
            return rec
        }
        guard let host = withLock({ self.host }) else {
            abortSession(sessionID: sessionID)
            throw MSLError.configuration("VM not running")
        }
        do {
            return try DataPlane.open(
                host: host, sessionID: sessionID, token: record.guestToken,
                timeout: min(config.bootTimeout, 15))
        } catch {
            abortSession(sessionID: sessionID)
            throw error
        }
    }

    /// Ensure the VM + distro are up, then open the guest GUI surface plane
    /// (vsock 5020). The raw fd is relayed to the client; `endGuiConnect` must
    /// balance this call once the relay ends. Holds an op reference meanwhile so
    /// the VM is not idle-reaped under a live presenter.
    public func beginGuiConnect(name: String?) throws -> Int32 {
        beginOp()
        do {
            let entry = try ensureUp(name)
            assert(!entry.name.isEmpty, "resolved distro name must not be empty")
            guard let host = withLock({ self.host }) else {
                throw MSLError.configuration("VM not running")
            }
            let fd = try host.connectRaw(port: GuiProto.port, timeout: min(config.bootTimeout, 5))
            assert(fd >= 0, "connectRaw returns a valid fd or throws")
            return fd
        } catch {
            endOp()
            throw error
        }
    }

    /// Balance a successful `beginGuiConnect` when its relay finishes.
    public func endGuiConnect() {
        endOp()
        withLock { lastActivity = Date() }
    }

    /// Reap a session whose relay ended normally (guest closed on child exit).
    public func endSession(sessionID: UInt64) {
        reap(sessionID: sessionID, kill: false)
    }

    /// Forced reap for a session with no live relay (attach failure, ACK
    /// failure, or an unattached orphan): SIGKILL the guest child, then reap.
    public func abortSession(sessionID: UInt64) {
        reap(sessionID: sessionID, kill: true)
    }

    // Two-phase teardown: reap the guest side now, cache the exit code locally
    // until the client's wait consumes it (the orphan reaper clears strays).
    private func reap(sessionID: UInt64, kill: Bool) {
        if withLock({ sessions.consumeFinished(sessionID: sessionID) }) != nil {
            withLock { lastActivity = Date() }
            return
        }
        let control = withLock { self.control }
        if kill { try? control?.sessionSignal(sessionID: sessionID, signal: SIGKILL) }
        var exit: Int32?
        for _ in 0..<50 {  // bounded: at most 50 * 10ms for the guest reap
            guard let waited = try? control?.sessionWait(sessionID: sessionID) else { break }
            if waited.done {
                exit = waited.exitCode
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        withLock {
            sessions.markFinished(sessionID: sessionID, exitCode: exit)
            lastActivity = Date()
        }
    }

    public func resize(sessionID: UInt64, rows: UInt16, cols: UInt16) throws {
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        try control.sessionResize(sessionID: sessionID, rows: rows, cols: cols)
        withLock { lastActivity = Date() }
    }

    public func signal(sessionID: UInt64, signal: Int32) throws {
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        try control.sessionSignal(sessionID: sessionID, signal: signal)
        withLock { lastActivity = Date() }
    }

    public func wait(sessionID: UInt64) throws -> LocalWaitData {
        let cached = withLock { sessions.consumeFinished(sessionID: sessionID) }
        if let cached {
            withLock { lastActivity = Date() }
            return LocalWaitData(done: true, exitCode: cached)
        }
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        do {
            let waited = try control.sessionWait(sessionID: sessionID)
            withLock { lastActivity = Date() }
            return LocalWaitData(done: waited.done, exitCode: waited.exitCode)
        } catch {
            // The relay-end reap may have consumed the guest entry but not yet
            // cached the code locally; give that in-flight reap a moment.
            for _ in 0..<50 {  // bounded: at most 50 * 10ms
                if let cached = withLock({ sessions.consumeFinished(sessionID: sessionID) }) {
                    withLock { lastActivity = Date() }
                    return LocalWaitData(done: true, exitCode: cached)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw error
        }
    }

    /// Graceful teardown for `msl shutdown`: down-all + VM stop. The caller exits.
    public func shutdown() {
        lifecycleQueue.sync { performStop() }
    }

    func withLock<Value>(_ body: () -> Value) -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func withLockThrowing<Value>(_ body: () throws -> Value) throws -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("msld: \(message)\n".utf8))
    }
}
