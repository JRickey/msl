import Darwin
import Foundation

/// Local-terminal control: raw mode entry/exit and window-size queries. A saved
/// `termios` is returned from `makeRaw` and must be handed back to `restore`.
public enum Terminal {
    /// Put `fd` into cfmakeraw mode, returning the prior attributes to restore.
    /// Returns nil when `fd` is not a tty (e.g. piped stdin) — attach still runs.
    public static func makeRaw(_ fd: Int32) throws -> termios? {
        guard fd >= 0 else { throw MSLError.io("terminal fd is invalid") }
        guard isatty(fd) == 1 else { return nil }
        var saved = termios()
        guard tcgetattr(fd, &saved) == 0 else {
            throw MSLError.io("tcgetattr failed: errno=\(errno)")
        }
        var raw = saved
        cfmakeraw(&raw)
        guard tcsetattr(fd, TCSAFLUSH, &raw) == 0 else {
            throw MSLError.io("tcsetattr(raw) failed: errno=\(errno)")
        }
        return saved
    }

    /// Restore previously saved attributes; best-effort (never throws so it is
    /// safe on every teardown path, including signal handlers).
    public static func restore(_ fd: Int32, _ saved: termios?) {
        guard fd >= 0, var attrs = saved else { return }
        _ = tcsetattr(fd, TCSAFLUSH, &attrs)
    }

    /// Read the current window size of `fd`; nil when unavailable.
    public static func windowSize(_ fd: Int32) -> (rows: UInt16, cols: UInt16)? {
        guard fd >= 0 else { return nil }
        var ws = winsize()
        guard ioctl(fd, TIOCGWINSZ, &ws) == 0 else { return nil }
        guard ws.ws_row > 0, ws.ws_col > 0 else { return nil }
        return (ws.ws_row, ws.ws_col)
    }
}
