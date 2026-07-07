import Darwin
import Foundation

/// A spawned mac child: its pid and the host-side stdio endpoints to pump.
public struct MacProcess: Sendable {
    public let pid: pid_t
    public let stdio: MacStdio
}

/// Host-side stdio for a spawned child. `pty` carries the master; `pipes`
/// carries the parent ends (stdin write, stdout read, stderr read).
public enum MacStdio: Sendable {
    case pty(primary: Int32)
    case pipes(stdin: Int32, stdout: Int32, stderr: Int32)
}

/// A tty spawn request with the initial window size to seat on the master.
public struct TTYRequest: Sendable {
    public let rows: UInt16
    public let cols: UInt16

    public init(rows: UInt16, cols: UInt16) {
        self.rows = rows
        self.cols = cols
    }
}

/// posix_spawn-only mac process spawning for the interop channel. No protocol
/// knowledge: callers translate the cwd/env and pump the returned stdio.
public enum MacExec {
    /// Spawn `argv[0]` (PATH-resolved) in `cwd` with the inherited environment
    /// plus `extraEnv`. A `tty` request routes stdio through a pty; else pipes.
    public static func spawn(
        argv: [String], cwd: String, extraEnv: [String: String], tty: TTYRequest?
    ) throws -> MacProcess {
        guard !argv.isEmpty else { throw MSLError.invalidArgument("spawn argv is empty") }
        guard !cwd.isEmpty else { throw MSLError.invalidArgument("spawn cwd is empty") }
        let env = buildEnv(extraEnv)
        assert(!env.isEmpty, "env carries at least the inherited environment")
        if let tty {
            return try spawnPTY(argv: argv, cwd: cwd, env: env, tty: tty)
        }
        return try spawnPipes(argv: argv, cwd: cwd, env: env)
    }

    /// Reap `pid`, returning the exit code (128+signal on signal death) or -1 on
    /// an unexpected waitpid error. Blocks; call off any queue that must stay hot.
    public static func wait(pid: pid_t) -> Int32 {
        assert(pid > 0, "wait requires a positive pid")
        guard pid > 0 else { return -1 }
        var status: Int32 = 0
        for _ in 0..<1_000_000 {  // bounded: retried only on EINTR
            let result = waitpid(pid, &status, 0)
            if result == pid { return statusCode(status) }
            if result < 0 && errno == EINTR { continue }
            return -1
        }
        return -1
    }

    /// Map a guest cwd to a host path: `/mnt/mac[/…]` -> the share root (+ the
    /// remainder); everything else -> `home`. A `..` component in the remainder
    /// would escape the share root, so it falls back to `home`. Pure; unit-tested.
    public static func translateCwd(
        _ guestCwd: String, shareRoot: String?, home: String
    ) -> String {
        assert(!home.isEmpty, "home must not be empty")
        guard let shareRoot, !shareRoot.isEmpty else { return home }
        let prefix = "/mnt/mac"
        if guestCwd == prefix { return shareRoot }
        if guestCwd.hasPrefix(prefix + "/") {
            let remainder = guestCwd.dropFirst(prefix.count)  // keeps the leading slash
            assert(remainder.hasPrefix("/"), "remainder retains the separator")
            let escapes = remainder.split(separator: "/").contains("..")
            return escapes ? home : shareRoot + remainder
        }
        return home
    }

    /// Translate a binfmt target: a clean `/mnt/mac/…` path -> host absolute
    /// path; nil when outside the share, dot-dot-bearing, share off, or the bare
    /// share root (a directory, not a binary). Pure; unit-tested.
    public static func translateBinary(_ guestPath: String, shareRoot: String?) -> String? {
        guard let shareRoot, !shareRoot.isEmpty else { return nil }
        assert(shareRoot.hasPrefix("/"), "share root must be an absolute host path")
        let prefix = "/mnt/mac"
        guard guestPath.hasPrefix(prefix + "/") else { return nil }
        let remainder = guestPath.dropFirst(prefix.count)  // keeps the leading slash
        assert(remainder.hasPrefix("/"), "remainder retains the separator")
        let components = remainder.split(separator: "/")
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return shareRoot + remainder
    }

    private static func spawnPTY(
        argv: [String], cwd: String, env: [String], tty: TTYRequest
    ) throws -> MacProcess {
        assert(!argv.isEmpty, "argv validated by caller")
        assert(!cwd.isEmpty, "cwd must not be empty")
        var primary: Int32 = -1
        var secondary: Int32 = -1
        var win = winsize(ws_row: tty.rows, ws_col: tty.cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &win) == 0 else {
            throw MSLError.io("openpty failed: errno=\(errno)")
        }
        let secondaryPath = try ttyPath(secondary)
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closePair(primary, secondary)
            throw MSLError.io("posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, secondaryPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        // The child must not inherit either pty end beyond its stdio: a
        // grandchild daemon holding the master (or a stray slave fd) would keep
        // the host side from ever seeing EOF on this pty. The > 2 guards keep
        // the closes off the freshly wired stdio fds.
        if primary > 2 { posix_spawn_file_actions_addclose(&actions, primary) }
        if secondary > 2 { posix_spawn_file_actions_addclose(&actions, secondary) }
        posix_spawn_file_actions_addchdir(&actions, cwd)
        var attr = try makeSIDAttr()
        defer { posix_spawnattr_destroy(&attr) }
        do {
            let pid = try launch(argv: argv, env: env, actions: &actions, attr: &attr)
            _ = Darwin.close(secondary)
            return MacProcess(pid: pid, stdio: .pty(primary: primary))
        } catch {
            closePair(primary, secondary)
            throw error
        }
    }

    private static func spawnPipes(
        argv: [String], cwd: String, env: [String]
    ) throws -> MacProcess {
        assert(!argv.isEmpty, "argv validated by caller")
        assert(!cwd.isEmpty, "cwd must not be empty")
        let stdinPipe = try makePipe()
        let stdoutPipe = try makePipe()
        let stderrPipe = try makePipe()
        let all = [stdinPipe, stdoutPipe, stderrPipe]
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeAll(all)
            throw MSLError.io("posix_spawn_file_actions_init failed")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        wirePipes(&actions, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
        posix_spawn_file_actions_addchdir(&actions, cwd)
        var attr = try makeSIDAttr()
        defer { posix_spawnattr_destroy(&attr) }
        do {
            let pid = try launch(argv: argv, env: env, actions: &actions, attr: &attr)
            closeChildEnds(stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
            return MacProcess(
                pid: pid,
                stdio: .pipes(
                    stdin: stdinPipe.write, stdout: stdoutPipe.read, stderr: stderrPipe.read))
        } catch {
            closeAll(all)
            throw error
        }
    }

    private static func wirePipes(
        _ actions: inout posix_spawn_file_actions_t?,
        stdin: (read: Int32, write: Int32),
        stdout: (read: Int32, write: Int32),
        stderr: (read: Int32, write: Int32)
    ) {
        assert(stdin.read >= 0 && stdout.write >= 0, "pipe ends must be valid")
        posix_spawn_file_actions_adddup2(&actions, stdin.read, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout.write, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr.write, 2)
        let ends = [
            stdin.read, stdin.write, stdout.read, stdout.write, stderr.read, stderr.write,
        ]
        for fd in ends {  // bounded: six pipe ends
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        assert(ends.count == 6, "child inherits only the dup'd 0/1/2")
    }

    private static func launch(
        argv: [String], env: [String],
        actions: inout posix_spawn_file_actions_t?, attr: inout posix_spawnattr_t?
    ) throws -> pid_t {
        assert(!argv.isEmpty, "argv must not be empty")
        let exe = argv[0]
        assert(!exe.isEmpty, "argv[0] must not be empty")
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargv.append(nil)
        var cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cenv.append(nil)
        defer {
            for ptr in cargv where ptr != nil { free(ptr) }  // bounded: argv length
            for ptr in cenv where ptr != nil { free(ptr) }  // bounded: env length
        }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, exe, &actions, &attr, cargv, cenv)
        guard rc == 0 else { throw MSLError.io("posix_spawnp(\(exe)) failed: rc=\(rc)") }
        assert(pid > 0, "spawn returned a non-positive pid")
        return pid
    }

    private static func buildEnv(_ extra: [String: String]) -> [String] {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in extra where !key.isEmpty {  // bounded: caller env keys
            merged[key] = value
        }
        assert(merged.count >= extra.filter { !$0.key.isEmpty }.count, "merge cannot drop keys")
        return merged.map { "\($0.key)=\($0.value)" }
    }

    private static func ttyPath(_ fd: Int32) throws -> String {
        assert(fd >= 0, "slave fd must be valid")
        var buffer = [CChar](repeating: 0, count: 1024)
        guard ttyname_r(fd, &buffer, buffer.count) == 0 else {
            throw MSLError.io("ttyname_r failed: errno=\(errno)")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8), !path.isEmpty else {
            throw MSLError.io("ttyname_r returned an invalid path")
        }
        return path
    }

    private static func makeSIDAttr() throws -> posix_spawnattr_t? {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            throw MSLError.io("posix_spawnattr_init failed")
        }
        let rc = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        assert(rc == 0, "setflags on a fresh attr cannot fail")
        guard rc == 0 else {
            posix_spawnattr_destroy(&attr)
            throw MSLError.io("posix_spawnattr_setflags failed: rc=\(rc)")
        }
        return attr
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.pipe(base)
        }
        guard rc == 0 else { throw MSLError.io("pipe() failed: errno=\(errno)") }
        assert(fds[0] >= 0 && fds[1] >= 0, "pipe returned invalid fds")
        return (read: fds[0], write: fds[1])
    }

    private static func closeChildEnds(
        stdin: (read: Int32, write: Int32),
        stdout: (read: Int32, write: Int32),
        stderr: (read: Int32, write: Int32)
    ) {
        assert(stdin.read >= 0, "stdin read end must be valid")
        _ = Darwin.close(stdin.read)
        _ = Darwin.close(stdout.write)
        _ = Darwin.close(stderr.write)
        assert(stdin.write >= 0, "parent retains the stdin write end")
    }

    private static func closeAll(_ pipes: [(read: Int32, write: Int32)]) {
        assert(pipes.count <= 3, "at most three stdio pipes")
        for pipe in pipes {  // bounded: three pipes
            if pipe.read >= 0 { _ = Darwin.close(pipe.read) }
            if pipe.write >= 0 { _ = Darwin.close(pipe.write) }
        }
    }

    private static func closePair(_ first: Int32, _ second: Int32) {
        if first >= 0 { _ = Darwin.close(first) }
        if second >= 0 { _ = Darwin.close(second) }
    }

    private static func statusCode(_ status: Int32) -> Int32 {
        let lower = status & 0x7f
        if lower == 0 { return (status >> 8) & 0xff }  // exited: WEXITSTATUS
        assert(lower != 0x7f, "no WUNTRACED requested; child cannot be stopped")
        return 128 + lower  // signal death: 128 + WTERMSIG
    }
}
