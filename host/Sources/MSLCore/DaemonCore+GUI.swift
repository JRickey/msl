import Foundation

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

    /// Launch one GUI app in the distro and, if no presenter is serving this
    /// runtime yet, spawn one. Preparing the runtime here (not in the CLI) makes
    /// the launch atomic: the record exists before the app is counted or a
    /// presenter is spawned against it.
    public func guiLaunch(_ req: GuiLaunchReq) throws -> ExecData {
        beginOp()
        defer { endOp() }
        let prepared = try prepareGuiRuntime(distro: req.distro, user: req.user)
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        let launch = GuiLaunchReq(
            distro: prepared.key.distro, user: req.user, argv: req.argv, env: req.env, cwd: req.cwd)
        let data = try control.guiLaunch(launch)
        guard data.exitCode == 0 else { return data }
        withLock {
            guiRuntimes.noteLaunchedProcess(key: prepared.key)
            lastActivity = Date()
        }
        trySpawnPresenter(key: prepared.key)
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

    /// Spawn `msl-presenter` for this runtime unless one is already attached or a
    /// spawn is in flight. The lease claim, token mint, and spawn are one unit: a
    /// failed spawn returns the lease to idle so a later launch retries.
    private func trySpawnPresenter(key: GuiRuntimeTable.Key) {
        assert(!key.distro.isEmpty, "presenter spawn needs a distro")
        let now = Date()
        let deadline = now.addingTimeInterval(guiAttachDeadline)
        let token = Token.generate()
        let claimed = withLock {
            guiRuntimes.beginPresenterSpawn(key: key, token: token, deadline: deadline, now: now)
        }
        guard claimed else { return }
        do {
            try GuiPresenterLauncher.spawn(home: config.home, key: key, token: token)
            withLock { lastActivity = Date() }
        } catch {
            withLock { guiRuntimes.abortPresenterSpawn(key: key, token: token) }
            log("GUI presenter spawn failed for \(key.label): \(error)")
        }
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
