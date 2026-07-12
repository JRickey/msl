import Darwin
import Foundation

/// Accepts guest-initiated interop connections on the VM queue and hands each to
/// a detached `InteropSession`. `@unchecked Sendable`: `liveSessions`/`accepting`
/// are guarded by `lock`; nothing else shared is mutated after init.
final class InteropListener: ReverseVsockHandler, @unchecked Sendable {
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
    }

    /// Stop admitting new connections; in-flight sessions run to completion.
    func stop() {
        withLock { accepting = false }
    }

    /// VM-queue callback: must return fast. The adapter already dup'd the fd;
    /// decide admission and hand off to a session thread.
    func handleReverseConnection(fd: Int32, port: UInt32) -> Bool {
        let decision = admit()
        guard decision != .reject else {
            _ = Darwin.close(fd)
            return false
        }
        startSession(fd: fd, admitted: decision == .accept)
        return true
    }

    func handleReverseAcceptFailure(errno code: Int32, port: UInt32) {
        logger("interop: dup failed errno=\(code)")
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

extension DaemonCore {
    /// Install the reverse interop listener (vsock 5010) when enabled. A refused
    /// install is logged, not fatal — the rest of the daemon still serves.
    func installInterop(host: VMHost) {
        guard config.interopEnabled else { return }
        let listener = makeInteropListener()
        guard host.setReverseListener(listener, port: Proto.interopPort) else {
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
