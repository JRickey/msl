import Darwin
import Foundation

/// Auto-spawns the resident daemon through the resolved msl CLI, detached with
/// stdio wired to the daemon log.
public enum SpawnDaemon {
    /// Resolve the bundled CLI for app callers, or the current CLI otherwise.
    public static func selfExecutablePath() -> String {
        let currentPath: String
        if let bundlePath = Bundle.main.executablePath, !bundlePath.isEmpty {
            currentPath = bundlePath
        } else {
            let argv0 = CommandLine.arguments.first ?? "msl"
            currentPath = URL(fileURLWithPath: argv0).standardizedFileURL.path
        }
        return MSLExecutableResolver.resolve(currentExecutablePath: currentPath)
    }

    /// Spawn the daemon detached. Throws if the log cannot be prepared or
    /// `posix_spawn` fails. Returns the child pid on success.
    @discardableResult
    public static func spawn(home: MSLHome) throws -> pid_t {
        try home.ensureDirectories()
        let logPath = home.logsDirectory.appendingPathComponent(LocalProto.logName).path
        let exe = selfExecutablePath()
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            throw MSLError.configuration("cannot locate msl executable to spawn daemon: \(exe)")
        }
        var actions = try makeFileActions(logPath: logPath)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr = try makeAttributes()
        defer { posix_spawnattr_destroy(&attr) }
        return try launch(exe: exe, actions: &actions, attr: &attr)
    }

    private static func makeFileActions(
        logPath: String
    ) throws -> posix_spawn_file_actions_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw MSLError.io("posix_spawn_file_actions_init failed")
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        let mode = mode_t(0o644)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, mode)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        return actions
    }

    private static func makeAttributes() throws -> posix_spawnattr_t? {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            throw MSLError.io("posix_spawnattr_init failed")
        }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        return attr
    }

    private static func launch(
        exe: String, actions: inout posix_spawn_file_actions_t?, attr: inout posix_spawnattr_t?
    ) throws -> pid_t {
        let args = [exe, "daemon", "run", "--spawned"]
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        defer {
            for ptr in cargs where ptr != nil { free(ptr) }  // bounded: argv length
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, cargs, environ)
        guard rc == 0 else {
            throw MSLError.io("posix_spawn(\(exe)) failed: rc=\(rc)")
        }
        return pid
    }
}
