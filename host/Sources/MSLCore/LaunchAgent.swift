import Darwin
import Foundation

/// Renders and (un)installs the per-user LaunchAgent that keeps the daemon
/// resident. Rendering is pure so the plist is unit-testable; install/uninstall
/// are best-effort wrappers around `launchctl` with clear errors.
public enum LaunchAgent {
    public static let label = "dev.msl.daemon"

    /// `~/Library/LaunchAgents/dev.msl.daemon.plist`.
    public static func plistPath(homeDirectory: String = NSHomeDirectory()) -> String {
        precondition(!homeDirectory.isEmpty, "home directory must not be empty")
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    }

    /// Render the launchd plist. `arguments` follow the resolved binary in
    /// ProgramArguments (default: the daemon foreground command).
    public static func render(
        executablePath: String, arguments: [String] = ["daemon", "run"]
    ) -> String {
        precondition(!executablePath.isEmpty, "executable path must not be empty")
        precondition(!arguments.isEmpty, "arguments must not be empty")
        let programArgs = ([executablePath] + arguments)
            .map { "        <string>\(escape($0))</string>" }
            .joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
            \(programArgs)
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                </dict>
            </dict>
            </plist>
            """
    }

    /// Write the plist and bootstrap it into the GUI domain. Overwrites any
    /// existing plist so a re-install picks up a new binary path.
    public static func install(executablePath: String) throws {
        let path = plistPath()
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist = render(executablePath: executablePath)
        try Data(plist.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        _ = runLaunchctl(["bootout", guiDomain()])  // clear a stale registration
        let result = runLaunchctl(["bootstrap", guiDomain(), path])
        guard result.code == 0 else {
            throw MSLError.configuration("launchctl bootstrap failed: \(result.output)")
        }
    }

    /// Bootout the agent and remove its plist. A missing plist is not an error.
    public static func uninstall() throws {
        let path = plistPath()
        _ = runLaunchctl(["bootout", "\(guiDomain())/\(label)"])
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private static func guiDomain() -> String {
        return "gui/\(Darwin.getuid())"
    }

    private static func runLaunchctl(_ args: [String]) -> (code: Int32, output: String) {
        assert(!args.isEmpty, "launchctl needs arguments")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    private static func escape(_ text: String) -> String {
        return text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
