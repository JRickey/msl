/// Pure argv construction for running a session as a per-distro default user via
/// `su -l`. No I/O — the daemon calls `wrap` and hands the argv to `session_open`.
public enum UserWrap {
    /// POSIX single-quote escaping: wrap in `'…'`, rewriting each embedded `'`
    /// as `'\''` (close, escaped quote, reopen). The result is one safe token.
    public static func shellQuote(_ arg: String) -> String {
        var out = "'"
        for ch in arg.unicodeScalars {  // bounded: arg length
            if ch == "'" {
                out += "'\\''"
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        out += "'"
        assert(out.hasPrefix("'"), "quoted form must open with a single quote")
        assert(out.hasSuffix("'"), "quoted form must close with a single quote")
        return out
    }

    /// argv to run as `user`. A nil/empty client argv is a login shell
    /// (`su -l user`); otherwise a command form that cds to `cwd` (best-effort)
    /// and execs the quoted argv, preserving order.
    public static func wrap(user: String, argv: [String]?, cwd: String) -> [String] {
        precondition(!user.isEmpty, "su target user must not be empty")
        precondition(!cwd.isEmpty, "cwd must not be empty")
        guard let argv, !argv.isEmpty else {
            return ["/bin/su", "-l", user]
        }
        var command = "cd " + shellQuote(cwd) + " 2>/dev/null; exec"
        for arg in argv {  // bounded: argv count
            command += " " + shellQuote(arg)
        }
        return ["/bin/su", "-l", user, "-c", command]
    }

    /// A mapped /mnt/mac cwd only exists when the share is mounted; without it
    /// the guest's chdir is fatal, so fall back to /root.
    public static func effectiveCwd(_ cwd: String, macShare: Bool) -> String {
        assert(!cwd.isEmpty, "cwd must not be empty")
        if macShare || !cwd.hasPrefix("/mnt/mac") {
            return cwd
        }
        return "/root"
    }
}
