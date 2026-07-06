import Foundation

public enum LauncherRuntime {
    public static func runBundle(_ app: URL, home: MSLHome) throws {
        let store = LauncherStore(home: home)
        let record = try store.record(in: app)
        guard record.isOwnedDistro else {
            throw MSLError.configuration("launcher is not owned by msl: \(app.path)")
        }
        try run(record: record, home: home)
    }

    public static func run(record: LauncherRecord, home: MSLHome) throws {
        try validateRegistered(home: home, name: record.distro)
        switch record.launchMode {
        case .shell:
            try openShell(home: home, name: record.distro)
        case .auto:
            try runAuto(home: home, name: record.distro)
        case .desktop:
            try launchDesktop(home: home, name: record.distro)
        }
    }

    public static func openShell(home: MSLHome, name: String) throws {
        try validateRegistered(home: home, name: name)
        let msl = SpawnDaemon.selfExecutablePath()
        let command =
            "MSL_HOME=\(LauncherStore.shellQuote(home.root.path)) "
            + "\(LauncherStore.shellQuote(msl)) shell \(LauncherStore.shellQuote(name))"
        try runAppleScript(
            """
            tell application "Terminal"
              activate
              do script \(appleScriptString(command))
            end tell
            """)
    }

    public static func launchDesktop(home: MSLHome, name: String) throws {
        let probe = try DesktopProbe.probe(home: home, name: name)
        guard let session = probe.session else {
            throw MSLError.configuration("no supported desktop session installed in \(name)")
        }
        throw MSLError.configuration(
            "desktop session '\(session.name)' is detected, but desktop launch is not certified yet"
        )
    }

    private static func runAuto(home: MSLHome, name: String) throws {
        let probe = try? DesktopProbe.probe(home: home, name: name)
        if probe?.available == true {
            do {
                try launchDesktop(home: home, name: name)
                return
            } catch {
                try openShell(home: home, name: name)
                return
            }
        }
        try openShell(home: home, name: name)
    }

    private static func runAppleScript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MSLError.io("Terminal launch failed with status \(process.terminationStatus)")
        }
    }

    private static func validateRegistered(home: MSLHome, name: String) throws {
        guard Registry.isValidName(name) else {
            throw MSLError.invalidArgument("invalid distro name: \(name)")
        }
        guard try Registry.load(from: home.registryURL).entry(name: name) != nil else {
            throw MSLError.invalidArgument("no such distro: \(name)")
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
