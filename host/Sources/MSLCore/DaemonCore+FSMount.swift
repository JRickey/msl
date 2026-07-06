import Darwin
import Foundation
import MSLFSWire

/// FSKit mount lifecycle for `DaemonCore` (ADR 0009). The daemon owns mount
/// state, the appex-admission listener, and cleanup; the CLI owns the actual
/// `/sbin/mount -F` and `/sbin/umount`. A live mount holds an activity
/// reference so idle VM shutdown cannot pull the rug from under Finder.
extension DaemonCore {
    /// Prepare a routed FSKit mount: ensure the distro, bind appex admission,
    /// record the nonce-backed mount, and return the CLI's URL and mountpoint.
    public func prepareMount(name: String?, readonly: Bool) throws -> MountPrepareData {
        let entry = try ensureUp(name)
        let distro = entry.name
        guard FSMountpoint.isValidDistroName(distro) else {
            throw MSLError.configuration("'\(distro)' is not a valid mount name")
        }
        guard let mountpoint = FSMountpoint.directory(distro: distro) else {
            throw MSLError.configuration("cannot resolve mountpoint for '\(distro)'")
        }
        try ensureMountListener()
        let record = mountTable.prepare(name: distro, mountpoint: mountpoint, readonly: readonly)
        guard
            let url = FSMountpoint.resourceURL(
                distro: distro, mountID: record.mountID, nonce: record.nonce,
                readonly: record.readonly)
        else {
            mountTable.remove(name: distro)
            throw MSLError.configuration("cannot build resource URL for '\(distro)'")
        }
        log("mount prepared for '\(distro)' at \(mountpoint)")
        return MountPrepareData(
            name: distro, url: url, mountpoint: mountpoint, mountID: record.mountID,
            nonce: record.nonce)
    }

    /// Commit the macOS mount and take an activity hold so live Finder volumes
    /// block idle VM shutdown.
    public func finishMount(name: String, mountpoint: String) throws {
        guard FSMountpoint.validate(mountpoint: mountpoint, distro: name) else {
            throw MSLError.configuration("mountpoint '\(mountpoint)' invalid for '\(name)'")
        }
        try mountTable.commit(name: name, mountpoint: mountpoint)
        beginOp()
        withLock { lastActivity = Date() }
        log("mount committed for '\(name)' at \(mountpoint)")
    }

    /// Tear down a mount: force-unmount as a safety net, drop the activity hold if
    /// it was live, and remove the record. Tolerant of an already-gone mount.
    public func unmount(name: String, force: Bool) throws {
        guard let record = mountTable.record(name: name) else {
            throw MSLError.configuration("no mount for '\(name)'")
        }
        FSMountOps.forceUnmount(mountpoint: record.mountpoint, force: force)
        mountTable.remove(name: name)
        if record.phase == .mounted { endOp() }
        withLock { lastActivity = Date() }
        log("unmounted '\(name)'")
    }

    public func mountStatus() -> MountStatusData {
        let entries = mountTable.entries().map {
            MountEntry(name: $0.name, mountpoint: $0.mountpoint, state: $0.phase.rawValue)
        }
        return MountStatusData(mounts: entries)
    }

    /// Startup cleanup force-unmounts `mslfs` mounts under `~/msl`; daemon state
    /// is not adoptable, so discovered mounts are stale.
    public func reconcileMounts() {
        let base = FSMountpoint.base()
        let discovered = FSMountOps.discoverMounts(base: base)
        let known = Set(mountTable.entries().map { $0.mountpoint })
        let stale = FSAdmission.reconcile(discovered: discovered, known: known)
        for mountpoint in stale {  // bounded: discovered mount count
            let ok = FSMountOps.forceUnmount(mountpoint: mountpoint, force: true)
            log("reconcile: \(ok ? "cleared" : "could not clear") stale mount \(mountpoint)")
        }
    }

    public func stopMountListener() {
        let listener = withLock { () -> FSMountListener? in
            let owned = mountListener
            mountListener = nil
            return owned
        }
        listener?.stop()
    }

    /// Unmount and clear every mount before a planned VM stop (release holds).
    /// Caller is on the lifecycle queue.
    func drainMounts() {
        let records = mountTable.removeAll()
        for record in records where record.phase == .mounted {  // bounded: <=26
            endOp()
        }
        for record in records {  // bounded: <=26
            FSMountOps.forceUnmount(mountpoint: record.mountpoint, force: true)
        }
        if !records.isEmpty { log("cleared \(records.count) mount(s) before stop") }
    }

    /// Unmount a single distro's mount ahead of `distro_down` (release the hold).
    func unmountForDistroDown(_ name: String) {
        guard let record = mountTable.remove(name: name) else { return }
        if record.phase == .mounted { endOp() }
        FSMountOps.forceUnmount(mountpoint: record.mountpoint, force: true)
        log("unmounted '\(name)' before distro down")
    }

    /// Unexpected VM loss: release holds for live mounts, best-effort force
    /// unmount, and mark records failed so future ops surface ENODEV/EIO.
    func failMountsOnVMLoss() {
        for record in mountTable.entries() where record.phase == .mounted {  // bounded: <=26
            endOp()
            FSMountOps.forceUnmount(mountpoint: record.mountpoint, force: true)
        }
        mountTable.markAllFailed()
    }

    /// Lazily bind the appex-admission socket in the app-group container and
    /// start the accept loop. Serialized so concurrent prepares bind once.
    func ensureMountListener() throws {
        mountInitLock.lock()
        defer { mountInitLock.unlock() }
        if withLock({ mountListener != nil }) { return }
        let team = ProcessInfo.processInfo.environment["MSL_FSKIT_TEAM_ID"] ?? FSProto.defaultTeamID
        let requirement = FSAdmission.requirement(bundleID: FSProto.appexBundleID, teamID: team)
        let listener = FSMountListener(
            socketPath: FSProto.appexSocketPath(),
            authenticator: FSPeerAuthenticator(requirement: requirement),
            table: mountTable,
            connectGuest: { [weak self] hello in
                guard let self else { throw MSLError.configuration("daemon gone") }
                return try self.connectGuestFileService(hello)
            },
            logger: { [weak self] message in self?.log(message) })
        try listener.start()
        withLock { mountListener = listener }
        log("fs appex listener on \(FSProto.appexSocketPath())")
    }

    /// Connect vsock 5030 and send `fs_open`; return the fd only after guest ack
    /// so worker failure becomes an error instead of a Finder hang.
    private func connectGuestFileService(_ hello: FSHello) throws -> Int32 {
        guard let host = withLock({ self.host }), withLock({ running }) else {
            throw MSLError.configuration("VM not running")
        }
        guard withLock({ distrosUp.contains(hello.distro) }) else {
            throw MSLError.configuration("distro '\(hello.distro)' not running")
        }
        let timeout = min(config.bootTimeout, 10)
        let fd = try host.connectRaw(port: FSProto.vsockPort, timeout: timeout)
        assert(fd >= 0, "connectRaw returns a valid fd or throws")
        let framed = try VsockClient(fileDescriptor: fd)
        try framed.setReceiveTimeout(seconds: timeout)
        try framed.send(try FSGuestOpen(distro: hello.distro, readonly: hello.readonly).encoded())
        let reply = try DataHandshakeReply.decode(try framed.receive())
        guard reply.ok else {
            framed.close()
            throw MSLError.configuration(
                "guest fs worker failed for '\(hello.distro)': \(reply.error ?? "unknown")")
        }
        return framed.detachDescriptor()
    }
}
