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
        home: MSLHome, name: String?, argv: [String], term: String,
        extraEnv: [String: String] = [:]
    ) throws -> AttachOutcome {
        try ensureRunning(home)
        let control = try connect(home)
        defer { control.close() }
        let shellData = try control.shell(
            buildRequest(name: name, argv: argv, term: term, extraEnv: extraEnv))
        let attachConn = try connect(home)
        let dataFD = try attachConn.attachRaw(
            sessionID: shellData.sessionID, token: shellData.token)
        return try SessionAttach(
            control: control, sessionID: shellData.sessionID, dataFD: dataFD
        ).run()
    }

    public static func capture(
        home: MSLHome, name: String?, argv: [String], term: String = "dumb"
    ) throws -> ExecData {
        try ensureRunning(home)
        let control = try connect(home)
        defer { control.close() }
        return try control.capture(buildRequest(name: name, argv: argv, term: term))
    }

    public static func guiProbe(home: MSLHome, name: String) throws -> GuiProbeData {
        let control = try guiControl(home)
        defer { control.close() }
        return try control.guiProbe(GuiRuntimeReq(distro: name))
    }

    public static func guiStart(home: MSLHome, name: String) throws -> GuiRuntimeData {
        let control = try guiControl(home)
        defer { control.close() }
        return try control.guiStart(GuiRuntimeReq(distro: name))
    }

    public static func guiStatus(home: MSLHome, name: String) throws -> GuiRuntimeData {
        let control = try guiControl(home)
        defer { control.close() }
        return try control.guiStatus(GuiRuntimeReq(distro: name))
    }

    public static func guiStop(home: MSLHome, name: String) throws -> GuiRuntimeData {
        let control = try guiControl(home)
        defer { control.close() }
        return try control.guiStop(GuiRuntimeReq(distro: name))
    }

    public static func guiLaunch(home: MSLHome, req: GuiLaunchReq) throws -> ExecData {
        let control = try guiControl(home)
        defer { control.close() }
        return try control.guiLaunch(req)
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

    public static func up(_ home: MSLHome, name: String?) throws {
        try ensureRunning(home)
        let control = try connect(home)
        defer { control.close() }
        try control.up(name: name)
    }

    public static func shutdown(_ home: MSLHome) throws {
        let control = try connect(home)
        defer { control.close() }
        try control.shutdown()
    }

    public static func mountPrepare(
        _ home: MSLHome, name: String?, readonly: Bool
    ) throws -> MountPrepareData {
        try ensureRunning(home)
        let control = try connect(home)
        defer { control.close() }
        return try control.mountPrepare(name: name, readonly: readonly)
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

    public static func authStatus(_ home: MSLHome, name: String?) throws -> AuthStatusData {
        try ensureRunning(home)
        let control = try connect(home)
        defer { control.close() }
        return try control.authStatus(name: name)
    }

    private static func buildRequest(
        name: String?, argv: [String], term: String, extraEnv: [String: String] = [:]
    ) -> ShellRequest {
        let size = Terminal.windowSize(STDIN_FILENO) ?? Terminal.windowSize(STDOUT_FILENO)
        let cwd = mapSessionCwd(
            hostCwd: FileManager.default.currentDirectoryPath, home: NSHomeDirectory(),
            hasMacShare: true)
        var env = extraEnv
        env["TERM"] = term
        return ShellRequest(
            name: name, argv: argv.isEmpty ? nil : argv, env: env,
            rows: size?.rows ?? 40, cols: size?.cols ?? 120, cwd: cwd)
    }

    private static func guiControl(_ home: MSLHome) throws -> LocalClient {
        try ensureRunning(home)
        return try connect(home)
    }
}
