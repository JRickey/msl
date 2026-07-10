import Darwin
import Foundation

/// Spawns the out-of-process `msl-presenter` for a GUI runtime. The daemon never
/// links AppKit; it execs a sibling binary that does. The single-use attach token
/// is handed to the child over an inherited pipe read-end (a fixed fd), never on
/// argv or in the environment — an inherited pipe is owner-only, absent from
/// `ps`, and dies with the daemon.
public enum GuiPresenterLauncher {
    /// The presenter reads its attach token from this inherited fd. Chosen above
    /// stdio so it never collides with 0/1/2; `POSIX_SPAWN_CLOEXEC_DEFAULT` closes
    /// every other inherited descriptor, so only 0/1/2 and this survive the exec.
    public static let tokenFD: Int32 = 3

    /// Resolve the presenter next to the running `msl` binary — the layout in both
    /// a dev checkout (`.build/release/`) and the app bundle (`Contents/MacOS/`).
    public static func executablePath(
        selfPath: String = SpawnDaemon.selfExecutablePath()
    ) -> String {
        precondition(!selfPath.isEmpty, "self executable path must not be empty")
        let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("msl-presenter").path
        assert(!candidate.isEmpty, "resolved presenter path is non-empty")
        return candidate
    }

    static func spawn(home: MSLHome, key: GuiRuntimeTable.Key, token: String) throws {
        precondition(!token.isEmpty, "presenter token must not be empty")
        precondition(!key.distro.isEmpty, "presenter spawn needs a distro")
        let exe = executablePath()
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            throw MSLError.configuration("msl-presenter not found next to msl at \(exe)")
        }
        try home.ensureDirectories()
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw MSLError.io("pipe for presenter token failed: errno=\(errno)")
        }
        let readFD = fds[0]
        let writeFD = fds[1]
        assert(readFD >= 0 && writeFD >= 0, "pipe returns two valid descriptors")
        do {
            _ = try launch(exe: exe, home: home, key: key, readFD: readFD)
        } catch {
            _ = Darwin.close(readFD)
            _ = Darwin.close(writeFD)
            throw error
        }
        _ = Darwin.close(readFD)
        defer { _ = Darwin.close(writeFD) }
        try writeToken(token, to: writeFD)
    }

    private static func launch(
        exe: String, home: MSLHome, key: GuiRuntimeTable.Key, readFD: Int32
    ) throws -> pid_t {
        precondition(readFD >= 0, "token read fd must be valid")
        var actions = try makeFileActions(home: home, readFD: readFD)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr = try makeAttributes()
        defer { posix_spawnattr_destroy(&attr) }
        let args = [exe, home.root.path, key.distro, key.user, csvPath(home: home, key: key)]
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        defer {
            for ptr in cargs where ptr != nil { free(ptr) }  // bounded: argv length
        }
        var cenv: [UnsafeMutablePointer<CChar>?] = childEnv(home: home).map { strdup($0) }
        cenv.append(nil)
        defer {
            for ptr in cenv where ptr != nil { free(ptr) }  // bounded: env length
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, cargs, cenv)
        guard rc == 0 else { throw MSLError.io("posix_spawn(msl-presenter) failed: rc=\(rc)") }
        assert(pid > 0, "posix_spawn returns a live pid on success")
        return pid
    }

    private static func makeFileActions(
        home: MSLHome, readFD: Int32
    ) throws -> posix_spawn_file_actions_t? {
        assert(readFD >= 0, "token read fd must be valid")
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw MSLError.io("posix_spawn_file_actions_init failed")
        }
        let logPath = home.logsDirectory.appendingPathComponent("gui-presenter.log").path
        let mode = mode_t(0o644)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, mode)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_adddup2(&actions, readFD, tokenFD)
        assert(tokenFD >= 3, "token fd never collides with stdio")
        return actions
    }

    private static func makeAttributes() throws -> posix_spawnattr_t? {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            throw MSLError.io("posix_spawnattr_init failed")
        }
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        assert(flags != 0, "presenter spawn flags are set")
        posix_spawnattr_setflags(&attr, flags)
        return attr
    }

    static func writeToken(_ token: String, to fd: Int32) throws {
        precondition(fd >= 0, "token write fd must be valid")
        let bytes = Array(token.utf8)
        assert(!bytes.isEmpty, "token has bytes to write")
        var sent = 0
        let cap = bytes.count + 8  // bounded: each successful write advances >=1 byte
        for _ in 0..<cap {
            if sent == bytes.count { return }
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if written > 0 {
                sent += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw MSLError.io("presenter token write failed errno=\(errno)")
            }
        }
        throw MSLError.io("presenter token write did not complete within bound")
    }

    private static func childEnv(home: MSLHome) -> [String] {
        assert(!home.root.path.isEmpty, "home path is non-empty")
        var env = ProcessInfo.processInfo.environment
        env["MSL_HOME"] = home.root.path
        env["MSL_GUI_TOKEN_FD"] = String(tokenFD)
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func csvPath(home: MSLHome, key: GuiRuntimeTable.Key) -> String {
        assert(!key.distro.isEmpty, "csv path needs a distro")
        let safeUser = key.user.isEmpty ? "default" : key.user
        let name = "gui-\(key.distro)-\(safeUser).csv"
        return home.logsDirectory.appendingPathComponent(name).path
    }
}
