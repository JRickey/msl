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
        let hostname = try resolveHostname(resolved)
        return try lifecycleQueue.sync {
            try performBoot()
            guard let entry = withLock({ attached.first { $0.name == resolved } }) else {
                throw MSLError.configuration(
                    "'\(resolved)' installed after boot; restart the daemon to attach it")
            }
            try performDistroUp(entry: entry, hostname: hostname)
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
        let newHost = VMHost(spec: try makeBootSpec(diskPaths: mapping.diskPaths))
        try newHost.startAndWait(onStop: { [weak self] error, requested in
            self?.handleStop(error, requested: requested)
        })
        do {
            let newControl = try connectAndPing(host: newHost)
            finishBoot(host: newHost, control: newControl, entries: mapping.entries)
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

    private func finishBoot(host: VMHost, control: ControlClient, entries: [DeviceEntry]) {
        let wake = PowerWake(onWake: { [weak self] in self?.syncTimeIfRunning() })
        wake.start()
        withLock {
            self.host = host
            self.control = control
            self.attached = entries
            self.distrosUp = []
            self.powerWake = wake
            self.running = true
            self.lastActivity = Date()
        }
        syncTime(control)
        log("VM booted with \(entries.count) image(s) attached")
    }

    /// Bring one distro up on the guest (idempotent). Caller is on the lifecycle
    /// queue, so the `distrosUp` bookkeeping cannot race with stop/down.
    private func performDistroUp(entry: DeviceEntry, hostname: String) throws {
        if withLock({ distrosUp.contains(entry.name) }) { return }
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        let macShare = config.shareHomePath != nil
        let result = try control.distroUp(
            name: entry.name, dev: entry.dev, hostname: hostname, macShare: macShare)
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
        let wake = withLock { () -> PowerWake? in
            let saved = powerWake
            host = nil
            control = nil
            attached = []
            distrosUp = []
            sessions = SessionTable()
            powerWake = nil
            running = false
            return saved
        }
        wake?.stop()
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
        return StatusData(vm: "running", distros: distros, idleTimeoutS: config.idleTimeoutS)
    }

    private func makeBootSpec(diskPaths: [String]) throws -> BootSpec {
        precondition(!diskPaths.isEmpty, "boot needs at least one disk")
        let shares =
            config.shareHomePath.map { [ShareSpec(tag: "mac", hostPath: $0, readOnly: false)] }
            ?? []
        let logPath = config.home.logsDirectory.appendingPathComponent("msld-console.log").path
        return try BootSpec(
            kernelPath: config.kernelPath, initramfsPath: config.initramfsPath,
            commandLine: config.cmdline, cpuCount: config.cpus, memoryMiB: config.memoryMiB,
            consoleLogPath: logPath, execCommand: nil, timeout: config.bootTimeout,
            diskPaths: diskPaths, shares: shares)
    }

    func resolveName(_ requested: String?) throws -> String {
        let registry = try Registry.load(from: config.home.registryURL)
        return try registry.resolveDefault(requested: requested).name
    }

    private func resolveHostname(_ name: String) throws -> String {
        let registry = try Registry.load(from: config.home.registryURL)
        return registry.entry(name: name)?.hostname ?? name
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
