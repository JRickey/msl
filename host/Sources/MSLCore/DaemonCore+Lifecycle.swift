import Darwin
import Foundation

/// VM lifecycle for `DaemonCore`: boot, distro up, stop, orphan/idle reaping.
/// Every mutation here runs on `lifecycleQueue` (or is invoked from an op that
/// does), so boot/distro_up/down/stop are atomic with respect to one another.
extension DaemonCore {
    /// Ensure the VM is booted and `name` is running, all on the lifecycle queue
    /// so boot and distro_up are atomic with respect to down/stop.
    func ensureUp(_ name: String?) throws -> DeviceEntry {
        let resolved = try resolveName(name)
        return try lifecycleQueue.sync {
            try performBoot()
            let settings = try distroSettings(resolved)
            guard let entry = withLock({ attached.first { $0.name == resolved } }) else {
                throw MSLError.configuration(
                    "'\(resolved)' installed after boot; restart the daemon to attach it")
            }
            try performDistroUp(
                entry: entry, hostname: settings.hostname, macShare: settings.macShare,
                rosetta: settings.rosetta)
            return entry
        }
    }

    /// Boot the VM if it is not already running. On any failure after the VM
    /// starts, stop it before rethrowing so a half-booted VM never leaks.
    private func performBoot() throws {
        guard !withLock({ running }) else { return }
        let registry = try Registry.load(from: config.home.registryURL)
        let mapping = DeviceMap.compute(
            names: registry.distros.map { $0.name },
            imagePath: { config.home.imageURL(name: $0).path },
            isReadable: { FileManager.default.isReadableFile(atPath: $0) })
        for name in mapping.skipped {  // bounded: registry list
            log("warning: skipping '\(name)' (image missing)")
        }
        guard !mapping.entries.isEmpty else {
            throw MSLError.configuration("no distro images to attach (install one first)")
        }
        let spec = try makeBootSpec(diskPaths: mapping.diskPaths)
        let newHost = VMHost(spec: spec)
        try newHost.startAndWait(onStop: { [weak self] error, requested in
            self?.handleStop(error, requested: requested)
        })
        do {
            let newControl = try connectAndPing(host: newHost)
            finishBoot(
                host: newHost, control: newControl, entries: mapping.entries,
                rosettaAttached: spec.rosettaShare)
        } catch {
            _ = newHost.stopAndWait()
            throw error
        }
    }

    private func connectAndPing(host: VMHost) throws -> ControlClient {
        let client = try ControlClient(client: try host.connectAndWait())
        let ping = try client.ping()
        if (ping.protocolVersion ?? 0) != Proto.version {
            log("warning: agent protocol \(ping.protocolVersion ?? 0) != \(Proto.version)")
        }
        return client
    }

    private func finishBoot(
        host: VMHost, control: ControlClient, entries: [DeviceEntry], rosettaAttached: Bool
    ) {
        let wake = PowerWake(onWake: { [weak self] in self?.syncTimeIfRunning() })
        wake.start()
        let forwarder = PortForwarder(
            connectGuest: makeForwardConnect(host: host),
            logger: { [weak self] message in self?.log(message) })
        withLock {
            self.host = host
            self.control = control
            self.attached = entries
            self.distrosUp = []
            self.rosettaAttached = rosettaAttached
            self.powerWake = wake
            self.forwarder = forwarder
            self.running = true
            self.lastActivity = Date()
        }
        syncTime(control)
        startMemoryLadder(host: host)
        forwarder.start()
        startPollTimer()
        installInterop(host: host)
        log("VM booted with \(entries.count) image(s) attached")
    }

    /// Drop the balloon target to the floor once control is up; on a device that
    /// refuses the target, park the ladder at the configured max (no ballooning).
    private func startMemoryLadder(host: VMHost) {
        let floor = config.memoryFloorMiB
        let seated = host.setBalloonTarget(mib: floor)
        withLock { balloonTargetMiB = seated ? floor : config.memoryMiB }
        assert(config.memoryFloorMiB <= config.memoryMiB, "floor must not exceed max")
    }

    private func startPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        let interval = config.pollIntervalS
        assert(interval > 0, "poll interval must be positive")
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.pollTick() }
        timer.resume()
        withLock { pollTimer = timer }
    }

    /// Build the closure `PortForwarder` uses to reach the guest: connect vsock
    /// 5003, send the `ForwardHello`, verify the reply, and hand back the raw fd.
    private func makeForwardConnect(host: VMHost) -> @Sendable (UInt16) throws -> Int32 {
        let timeout = min(config.bootTimeout, 15)
        return { port in
            precondition(port > 0, "forward port must be positive")
            let fd = try host.connectRaw(port: Proto.forwardPort, timeout: timeout)
            let framed = try VsockClient(fileDescriptor: fd)
            try framed.setReceiveTimeout(seconds: timeout)
            try framed.send(try ForwardHello(port: port).encoded())
            let reply = try DataHandshakeReply.decode(try framed.receive())
            guard reply.ok else {
                framed.close()
                throw MSLError.protocolMismatch(
                    "forward handshake rejected: \(reply.error ?? "unknown")")
            }
            return framed.detachDescriptor()
        }
    }

    /// Bring one distro up on the guest (idempotent). Caller is on the lifecycle
    /// queue, so the `distrosUp` bookkeeping cannot race with stop/down.
    private func performDistroUp(
        entry: DeviceEntry, hostname: String, macShare: Bool, rosetta: Bool
    ) throws {
        assert(!entry.name.isEmpty, "device entry name must not be empty")
        assert(!hostname.isEmpty, "hostname must not be empty")
        if withLock({ distrosUp.contains(entry.name) }) { return }
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        let result = try control.distroUp(
            name: entry.name, dev: entry.dev, hostname: hostname, macShare: macShare,
            rosetta: rosetta)
        guard result.state == "running" else {
            throw MSLError.configuration("distro '\(entry.name)' failed to start: \(result.state)")
        }
        syncTime(control)
        withLock {
            distrosUp.insert(entry.name)
            lastActivity = Date()
        }
    }

    /// Down every running distro (ordered) then stop the VM. Caller must be on
    /// the lifecycle queue; the daemon stays resident.
    func performStop() {
        guard let control = withLock({ self.control }), let host = withLock({ self.host })
        else { return }
        for name in withLock({ Array(distrosUp) }).sorted() {  // bounded: <=26 distros
            _ = try? control.distroDown(name: name, timeoutMs: 15000)
        }
        _ = host.stopAndWait()
        teardownState()
        log("VM stopped")
    }

    private func teardownState() {
        let saved = withLock { () -> TeardownBundle in
            let bundle = TeardownBundle(
                wake: powerWake, forwarder: forwarder, pollTimer: pollTimer,
                interop: interopListener, host: host)
            host = nil
            control = nil
            attached = []
            distrosUp = []
            rosettaAttached = false
            sessions = SessionTable()
            powerWake = nil
            forwarder = nil
            interopListener = nil
            pollTimer = nil
            balloonTargetMiB = 0
            comfortTicks = 0
            reclaimedThisIdle = false
            lastMemStats = nil
            running = false
            return bundle
        }
        saved.pollTimer?.cancel()
        saved.interop?.stop()
        saved.host?.removeInteropListener(port: Proto.interopPort)
        saved.forwarder?.stop()
        saved.wake?.stop()
    }

    /// Unexpected guest stop (crash): mark the VM down so the next op re-boots.
    private func handleStop(_ error: Error?, requested: Bool) {
        guard !requested, withLock({ running }) else { return }
        log("VM stopped unexpectedly; will re-boot on next use")
        teardownState()
    }

    /// Coarse tick: reap sessions no client attached to within the deadline, then
    /// stop the VM if it has been idle (no live or pending-unexpired sessions).
    func idleTick() {
        let now = Date()
        let expired = withLock { sessions.expiredPending(now: now, deadline: attachDeadline) }
        for sessionID in expired {  // bounded: session table (<=64)
            log("reaping session \(sessionID): no client attached within \(Int(attachDeadline))s")
            abortSession(sessionID: sessionID)
        }
        let stop = withLock { () -> Bool in
            guard running else { return false }
            return IdlePolicy.shouldStop(
                now: now, lastActivity: lastActivity,
                liveSessions: sessions.liveCountForIdle(now: now, deadline: attachDeadline),
                pendingOps: pendingOps, timeoutSeconds: config.idleTimeoutS)
        }
        guard stop else { return }
        lifecycleQueue.async { [weak self] in self?.performStop() }
    }

    /// 2 s telemetry tick: mirror guest listeners, feed the balloon ladder, and
    /// run the once-per-idle hygiene pass. Control errors skip the tick.
    func pollTick() {
        let snap = withLock {
            (running, control, host, forwarder)
        }
        guard snap.0, let control = snap.1, let host = snap.2 else { return }
        guard let stats = try? control.memStats() else { return }
        if let listeners = try? control.netListeners() {
            snap.3?.update(ports: listeners.ports)
        }
        withLock { lastMemStats = stats }
        updateComfort(stats: stats)
        let justReclaimed = runIdleHygiene(control: control)
        stepLadder(control: control, host: host, stats: stats, justReclaimed: justReclaimed)
    }

    private func updateComfort(stats: MemStatsData) {
        let target = withLock { balloonTargetMiB }
        assert(target >= 0, "balloon target is unsigned")
        let comfortable = stats.memAvailableKiB / 1024 > target / 2
        withLock { comfortTicks = comfortable ? min(comfortTicks + 1, 1_000_000) : 0 }
    }

    /// Fire `mem_reclaim` at most once per idle period (no live sessions, no
    /// pending ops, ≥30 s idle). Returns whether reclaim ran on this tick.
    private func runIdleHygiene(control: ControlClient) -> Bool {
        let now = Date()
        let idle = withLock { () -> Bool in
            let live = sessions.liveCountForIdle(now: now, deadline: attachDeadline)
            return live == 0 && pendingOps == 0 && now.timeIntervalSince(lastActivity) >= 30
        }
        guard idle else {
            withLock { reclaimedThisIdle = false }
            return false
        }
        guard withLock({ !reclaimedThisIdle }) else { return false }
        let didReclaim = (try? control.memReclaim()) != nil
        withLock { reclaimedThisIdle = true }
        return didReclaim
    }

    private func stepLadder(
        control: ControlClient, host: VMHost, stats: MemStatsData, justReclaimed: Bool
    ) {
        let inputs = withLock {
            MemoryLadder.Inputs(
                targetMiB: balloonTargetMiB, floorMiB: config.memoryFloorMiB,
                maxMiB: config.memoryMiB, availableMiB: stats.memAvailableKiB / 1024,
                psiSomeAvg10: stats.psiSomeAvg10, comfortTicks: comfortTicks,
                justReclaimed: justReclaimed)
        }
        let action = MemoryLadder.decide(inputs)
        guard let next = Self.ladderTarget(action) else { return }
        assert(next >= config.memoryFloorMiB, "ladder target must respect the floor")
        guard host.setBalloonTarget(mib: next) else { return }
        withLock {
            balloonTargetMiB = next
            if case .shrink = action { comfortTicks = 0 }
        }
    }

    private static func ladderTarget(_ action: MemoryLadder.Action) -> UInt64? {
        switch action {
        case .hold: return nil
        case .grow(let toMiB): return toMiB
        case .shrink(let toMiB): return toMiB
        }
    }

    func buildStatus(
        registry: Registry, attached: [DeviceEntry], guestStates: [DistroStateEntry]
    ) -> StatusData {
        let attachedNames = Set(attached.map { $0.name })
        let stateByName = Dictionary(
            guestStates.map { ($0.name, $0.state) }, uniquingKeysWith: { first, _ in first })
        let distros = registry.distros.map { entry -> DistroStatus in
            let state =
                attachedNames.contains(entry.name)
                ? (stateByName[entry.name] ?? "stopped") : "unavailable"
            let count = withLock { sessions.sessions(forName: entry.name) }
            return DistroStatus(name: entry.name, state: state, sessions: count)
        }
        let memory = withLock { () -> MemoryStatus in
            MemoryStatus(
                targetMiB: balloonTargetMiB, maxMiB: config.memoryMiB,
                availableMiB: (lastMemStats?.memAvailableKiB ?? 0) / 1024)
        }
        let ports = withLock { forwarder }?.mirroredPorts()
        return StatusData(
            vm: "running", distros: distros, idleTimeoutS: config.idleTimeoutS,
            memory: memory, forwardedPorts: ports)
    }

    private func makeBootSpec(diskPaths: [String]) throws -> BootSpec {
        precondition(!diskPaths.isEmpty, "boot needs at least one disk")
        let shares =
            config.shareHomePath.map { [ShareSpec(tag: "mac", hostPath: $0, readOnly: false)] }
            ?? []
        let logPath = config.home.logsDirectory.appendingPathComponent("msld-console.log").path
        let rosettaShare = try resolveRosettaShare()
        return try BootSpec(
            kernelPath: config.kernelPath, initramfsPath: config.initramfsPath,
            commandLine: config.cmdline, cpuCount: config.cpus, memoryMiB: config.memoryMiB,
            consoleLogPath: logPath, execCommand: nil, timeout: config.bootTimeout,
            diskPaths: diskPaths, shares: shares, balloonEnabled: true,
            rosettaShare: rosettaShare)
    }

    func resolveName(_ requested: String?) throws -> String {
        let registry = try Registry.load(from: config.home.registryURL)
        return try registry.resolveDefault(requested: requested).name
    }

    /// Per-distro boot settings from one registry load: hostname (default = the
    /// distro name), mac-home sharing, and Rosetta. Rosetta is gated on the share
    /// having actually attached this boot; the guest sets it up only if so.
    private func distroSettings(_ name: String) throws -> DistroBootSettings {
        assert(!name.isEmpty, "distro name must not be empty")
        let registry = try Registry.load(from: config.home.registryURL)
        let entry = registry.entry(name: name)
        let hostname = entry?.hostname ?? name
        let macShare = config.shareHomePath != nil && (entry?.macShare ?? true)
        let rosetta = (entry?.rosetta ?? false) && withLock { rosettaAttached }
        assert(!hostname.isEmpty, "resolved hostname must not be empty")
        return DistroBootSettings(hostname: hostname, macShare: macShare, rosetta: rosetta)
    }

    /// Session argv + cwd policy. A /mnt/mac cwd cannot exist in a distro that
    /// opted out of the share — fall back before the guest's fatal chdir.
    func resolveSession(
        name: String, requested: [String]?, cwd requestedCwd: String
    ) throws -> (argv: [String], cwd: String) {
        assert(!name.isEmpty, "distro name must not be empty")
        assert(!requestedCwd.isEmpty, "cwd must not be empty")
        let registry = try Registry.load(from: config.home.registryURL)
        let entry = registry.entry(name: name)
        let shareOn = config.shareHomePath != nil && (entry?.macShare ?? true)
        let cwd = UserWrap.effectiveCwd(requestedCwd, macShare: shareOn)
        guard let user = entry?.defaultUser else {
            return (requested ?? ["/bin/bash", "-l"], cwd)
        }
        return (UserWrap.wrap(user: user, argv: requested, cwd: cwd), cwd)
    }

    func mergedEnv(_ env: [String: String]?) -> [String: String] {
        var result = env ?? [:]
        if result["TERM"] == nil { result["TERM"] = config.term }
        return result
    }

    private func syncTimeIfRunning() {
        guard let control = withLock({ self.control }) else { return }
        syncTime(control)
    }

    private func syncTime(_ control: ControlClient) {
        let now = Date().timeIntervalSince1970
        let sec = Int64(now.rounded(.down))
        let usec = Int64((now - now.rounded(.down)) * 1_000_000)
        try? control.setTime(sec: sec, usec: usec)
    }

    func beginOp() { withLock { pendingOps += 1 } }
    func endOp() { withLock { pendingOps = max(0, pendingOps - 1) } }
}

/// The per-boot resources `teardownState` detaches under the lock and then stops
/// outside it (stopping a forwarder or timer must never hold `stateLock`).
private struct TeardownBundle {
    let wake: PowerWake?
    let forwarder: PortForwarder?
    let pollTimer: DispatchSourceTimer?
    let interop: InteropListener?
    let host: VMHost?
}
