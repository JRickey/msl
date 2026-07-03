import Darwin
import Foundation

/// Foreground runtime for `msl daemon run`: take the daemon lock (refusing a
/// second daemon), rebind over any stale socket, write the PID file, wire
/// graceful signals, then serve forever. `exit(_:)` is the sanctioned exit.
public enum DaemonRuntime: Sendable {
    /// Acquire + serve. Never returns except via `exit` (shutdown op or a signal).
    public static func run(config: DaemonConfig, spawned: Bool) -> Never {
        let home = config.home
        try? home.ensureDirectories()
        let socketPath = DaemonClient.socketPath(home)
        let pidPath = DaemonClient.pidPath(home)
        let lock = acquireLockOrFail(home: home, socketPath: socketPath)
        let listener: Int32
        do {
            listener = try LocalSocket.bindListener(path: socketPath)
        } catch {
            fail(error)
        }
        writePID(pidPath)
        if !spawned { log("listening on \(socketPath)") }
        let core = DaemonCore(config: config)
        core.startIdleTimer()
        let cleanup: @Sendable () -> Void = { teardown(core, lock, socketPath, pidPath) }
        installSignals(cleanup)
        let server = DaemonServer(
            core: core, listener: listener,
            onShutdown: {
                cleanup(); exit(0)
            })
        withExtendedLifetime(lock) { server.run() }
        exit(0)
    }

    /// Take the ownership lock; on contention enrich the message with a probe.
    private static func acquireLockOrFail(home: MSLHome, socketPath: String) -> DaemonLock {
        let lockPath = home.root.appendingPathComponent("msld.lock").path
        do {
            return try DaemonLock.acquire(path: lockPath)
        } catch {
            if LocalSocket.probeAlive(socketPath) {
                log("daemon already running (socket: \(socketPath))")
            }
            fail(error)
        }
    }

    /// Stop the VM, then unlink the socket + PID while still holding the lock so
    /// no successor can bind before this owner has fully released.
    private static func teardown(
        _ core: DaemonCore, _ lock: DaemonLock, _ socketPath: String, _ pidPath: String
    ) {
        core.shutdown()
        _ = Darwin.unlink(socketPath)
        _ = Darwin.unlink(pidPath)
        lock.release()
    }

    private static func installSignals(_ cleanup: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "msl.daemon.signal", qos: .userInitiated)
        for sig in [SIGINT, SIGTERM] {  // bounded: two signals
            Darwin.signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                cleanup(); exit(0)
            }
            source.resume()
            retainedSignalSources.append(source)
        }
    }

    private static func writePID(_ path: String) {
        let text = "\(Darwin.getpid())\n"
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func fail(_ error: Error) -> Never {
        let message = (error as? MSLError)?.description ?? error.localizedDescription
        log(message)
        exit(1)
    }

    private static func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("msld: \(message)\n".utf8))
    }
}

/// Signal sources must outlive `run()`'s stack frame; the accept loop blocks the
/// main thread, so a process-lifetime holder keeps them from being cancelled.
nonisolated(unsafe) private var retainedSignalSources: [DispatchSourceSignal] = []
