import Darwin
import Foundation

/// Client-side orchestration for the resident daemon: locate/auto-spawn it, then
/// drive control ops and interactive sessions. The terminal machinery is reused
/// wholesale from `SessionAttach`; only the control channel differs (`LocalClient`).
public enum DaemonClient {
    public static func socketPath(_ home: MSLHome) -> String {
        return home.root.appendingPathComponent(LocalProto.socketName).path
    }

    public static func pidPath(_ home: MSLHome) -> String {
        return home.root.appendingPathComponent(LocalProto.pidName).path
    }

    /// True when a daemon is accepting on the socket.
    public static func isRunning(_ home: MSLHome) -> Bool {
        return LocalSocket.probeAlive(socketPath(home))
    }

    public static func connect(_ home: MSLHome) throws -> LocalClient {
        return try LocalClient.connect(path: socketPath(home))
    }

    /// Ensure a daemon is up, auto-spawning one and polling the socket (250ms,
    /// up to 10s) when none is accepting yet.
    public static func ensureRunning(_ home: MSLHome) throws {
        let path = socketPath(home)
        if LocalSocket.probeAlive(path) { return }
        try SpawnDaemon.spawn(home: home)
        for _ in 0..<40 {  // bounded: 40 * 250ms = 10s
            if LocalSocket.probeAlive(path) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw MSLError.timedOut("daemon did not start within 10s (see \(home.logsDirectory.path))")
    }

    /// Open an interactive PTY session (shell/run) and attach the local terminal.
    /// Returns the session outcome so the caller maps it to an exit code.
    public static func runSession(
        home: MSLHome, name: String?, argv: [String], term: String
    ) throws -> AttachOutcome {
        try ensureRunning(home)
        let control = try connect(home)
        defer { control.close() }
        let shellData = try control.shell(buildRequest(name: name, argv: argv, term: term))
        let attachConn = try connect(home)
        let dataFD = try attachConn.attachRaw(
            sessionID: shellData.sessionID, token: shellData.token)
        return try SessionAttach(
            control: control, sessionID: shellData.sessionID, dataFD: dataFD
        ).run()
    }

    public static func status(_ home: MSLHome) throws -> StatusData {
        let control = try connect(home)
        defer { control.close() }
        return try control.status()
    }

    public static func down(_ home: MSLHome, name: String?, all: Bool) throws {
        let control = try connect(home)
        defer { control.close() }
        try control.down(name: name, all: all, timeoutMs: nil)
    }

    public static func shutdown(_ home: MSLHome) throws {
        let control = try connect(home)
        defer { control.close() }
        try control.shutdown()
    }

    public static func mountPrepare(_ home: MSLHome, name: String?) throws -> MountPrepareData {
        try ensureRunning(home)
        let control = try connect(home)
        defer { control.close() }
        return try control.mountPrepare(name: name)
    }

    public static func mountCommit(_ home: MSLHome, name: String, mountpoint: String) throws {
        let control = try connect(home)
        defer { control.close() }
        try control.mountCommit(name: name, mountpoint: mountpoint)
    }

    public static func mountUnmount(_ home: MSLHome, name: String, force: Bool) throws {
        let control = try connect(home)
        defer { control.close() }
        try control.mountUnmount(name: name, force: force)
    }

    public static func mountStatus(_ home: MSLHome) throws -> MountStatusData {
        let control = try connect(home)
        defer { control.close() }
        return try control.mountStatus()
    }

    private static func buildRequest(name: String?, argv: [String], term: String) -> ShellRequest {
        let size = Terminal.windowSize(STDIN_FILENO) ?? Terminal.windowSize(STDOUT_FILENO)
        let cwd = mapSessionCwd(
            hostCwd: FileManager.default.currentDirectoryPath, home: NSHomeDirectory(),
            hasMacShare: true)
        return ShellRequest(
            name: name, argv: argv.isEmpty ? nil : argv, env: ["TERM": term],
            rows: size?.rows ?? 40, cols: size?.cols ?? 120, cwd: cwd)
    }
}
