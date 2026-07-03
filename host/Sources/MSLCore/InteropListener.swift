import Darwin
import Foundation
import Virtualization

/// Accepts guest-initiated interop connections on the VM queue and hands each to
/// a detached `InteropSession`. `@unchecked Sendable`: `liveSessions`/`accepting`
/// are guarded by `lock`; nothing else shared is mutated after init.
final class InteropListener: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private let spawner: @Sendable (MacExecHello) throws -> MacProcess
    private let logger: @Sendable (String) -> Void
    private let beginActivity: @Sendable () -> Void
    private let endActivity: @Sendable () -> Void
    private let lock = NSLock()
    private var liveSessions = 0
    private var accepting = true

    static let maxSessions = 32

    init(
        spawner: @escaping @Sendable (MacExecHello) throws -> MacProcess,
        logger: @escaping @Sendable (String) -> Void,
        beginActivity: @escaping @Sendable () -> Void,
        endActivity: @escaping @Sendable () -> Void
    ) {
        self.spawner = spawner
        self.logger = logger
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        super.init()
    }

    /// Stop admitting new connections; in-flight sessions run to completion.
    func stop() {
        withLock { accepting = false }
    }

    /// VM-queue callback: must return fast. Dup the fd (independent of the VZ
    /// connection's lifetime), decide admission, hand off to a session thread.
    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let raw = Darwin.dup(connection.fileDescriptor)
        connection.close()
        guard raw >= 0 else {
            logger("interop: dup failed errno=\(errno)")
            return false
        }
        let decision = admit()
        guard decision != .reject else {
            _ = Darwin.close(raw)
            return false
        }
        startSession(fd: raw, admitted: decision == .accept)
        return true
    }

    private enum Decision { case accept, overCap, reject }

    private func admit() -> Decision {
        return withLock { () -> Decision in
            guard accepting else { return .reject }
            guard liveSessions < Self.maxSessions else { return .overCap }
            liveSessions += 1
            return .accept
        }
    }

    private func startSession(fd: Int32, admitted: Bool) {
        assert(fd >= 0, "session fd must be valid")
        let session = InteropSession(
            fd: fd, admitted: admitted, spawner: spawner, logger: logger,
            beginActivity: beginActivity, endActivity: endActivity)
        Thread.detachNewThread { [self] in
            session.run()
            if admitted { withLock { liveSessions = max(0, liveSessions - 1) } }
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension VMHost {
    /// Install `delegate` as the reverse listener for guest-initiated connects on
    /// `port` (interop 5010). The listener + delegate are retained here so they
    /// outlive the call (VZ holds only a weak delegate). False when no VM/device.
    public func setInteropListener<Delegate: VZVirtioSocketListenerDelegate & Sendable>(
        _ delegate: Delegate, port: UInt32
    ) -> Bool {
        precondition(port > 0, "interop port must be positive")
        let box = Box<Bool>(false)
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            defer { semaphore.signal() }
            guard let vm = self.machine,
                let device = vm.socketDevices.first as? VZVirtioSocketDevice
            else { return }
            let listener = VZVirtioSocketListener()
            listener.delegate = delegate
            device.setSocketListener(listener, forPort: port)
            self.interopListeners[port] = listener
            self.interopDelegates[port] = delegate
            box.value = true
        }
        semaphore.wait()
        return box.value
    }

    /// Remove the reverse listener for `port` and drop the retained objects.
    /// Safe to call on a stopped VM (the device lookup simply no-ops).
    public func removeInteropListener(port: UInt32) {
        assert(port > 0, "interop port must be positive")
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            defer { semaphore.signal() }
            let device = self.machine?.socketDevices.first as? VZVirtioSocketDevice
            device?.removeSocketListener(forPort: port)
            self.interopListeners[port] = nil
            self.interopDelegates[port] = nil
        }
        semaphore.wait()
    }
}

extension DaemonCore {
    /// Install the reverse interop listener (vsock 5010) when enabled. A refused
    /// install is logged, not fatal — the rest of the daemon still serves.
    func installInterop(host: VMHost) {
        guard config.interopEnabled else { return }
        let listener = makeInteropListener()
        guard host.setInteropListener(listener, port: Proto.interopPort) else {
            log("warning: interop listener install failed")
            return
        }
        withLock { interopListener = listener }
        log("interop listening on vsock:\(Proto.interopPort)")
    }

    /// Build the interop listener: a spawner that translates the guest cwd/env to
    /// host terms, plus activity closures so a running command blocks idle stop.
    private func makeInteropListener() -> InteropListener {
        let shareRoot = config.shareHomePath
        let home = NSHomeDirectory()
        assert(!home.isEmpty, "mac home path must not be empty")
        let spawner: @Sendable (MacExecHello) throws -> MacProcess = { hello in
            let cwd = MacExec.translateCwd(hello.cwd, shareRoot: shareRoot, home: home)
            let argv = try Self.resolveArgv(hello, shareRoot: shareRoot)
            var extra: [String: String] = [:]
            if let term = hello.env["TERM"] { extra["TERM"] = term }
            let tty = hello.tty ? TTYRequest(rows: hello.rows, cols: hello.cols) : nil
            return try MacExec.spawn(argv: argv, cwd: cwd, extraEnv: extra, tty: tty)
        }
        return InteropListener(
            spawner: spawner,
            logger: { [weak self] message in self?.log(message) },
            beginActivity: { [weak self] in self?.markInteropActivity(begin: true) },
            endActivity: { [weak self] in self?.markInteropActivity(begin: false) })
    }

    /// Resolve the argv to spawn: pass through in explicit mode; in binfmt mode
    /// translate argv[0] as a `/mnt/mac` share path and require it be executable.
    static func resolveArgv(_ hello: MacExecHello, shareRoot: String?) throws -> [String] {
        assert(!hello.argv.isEmpty, "hello.validate() already rejected empty argv")
        guard !hello.argv.isEmpty else { throw MSLError.invalidArgument("mac_exec argv is empty") }
        guard hello.binfmt else { return hello.argv }
        guard let target = MacExec.translateBinary(hello.argv[0], shareRoot: shareRoot),
            FileManager.default.isExecutableFile(atPath: target)
        else {
            throw MSLError.invalidArgument(
                "binfmt target must be an executable under /mnt/mac: \(hello.argv[0])")
        }
        assert(!target.isEmpty, "translateBinary never yields an empty path")
        var argv = hello.argv
        argv[0] = target
        return argv
    }

    /// Bracket one interop session as daemon activity: bump the pending-op count
    /// and the activity clock so the idle timer cannot stop the VM mid-command.
    private func markInteropActivity(begin: Bool) {
        if begin { beginOp() } else { endOp() }
        withLock { lastActivity = Date() }
    }
}
