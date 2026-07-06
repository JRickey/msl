import Foundation

public struct DesktopSession: Equatable, Sendable {
    public let name: String
    public let command: String

    public init(name: String, command: String) {
        precondition(!name.isEmpty, "desktop session name must not be empty")
        precondition(!command.isEmpty, "desktop command must not be empty")
        self.name = name
        self.command = command
    }
}

public struct DesktopProbeResult: Equatable, Sendable {
    public let session: DesktopSession?

    public init(session: DesktopSession?) {
        self.session = session
    }

    public var available: Bool { session != nil }
}

public enum DesktopProbe {
    public static let supported: [DesktopSession] = [
        DesktopSession(name: "gnome", command: "gnome-session"),
        DesktopSession(name: "kde", command: "startplasma-wayland"),
        DesktopSession(name: "xfce", command: "startxfce4"),
        DesktopSession(name: "xfce", command: "xfce4-session"),
        DesktopSession(name: "lxqt", command: "startlxqt"),
    ]

    public static func detect(commands: Set<String>) -> DesktopProbeResult {
        for session in supported where commands.contains(session.command) {
            return DesktopProbeResult(session: session)
        }
        return DesktopProbeResult(session: nil)
    }

    public static func probe(
        home: MSLHome, name: String, timeoutSeconds: Int = 8
    ) throws -> DesktopProbeResult {
        guard Registry.isValidName(name) else {
            throw MSLError.invalidArgument("invalid distro name: \(name)")
        }
        guard try Registry.load(from: home.registryURL).entry(name: name) != nil else {
            throw MSLError.invalidArgument("no such distro: \(name)")
        }
        let output = try runProbe(home: home, name: name, timeoutSeconds: timeoutSeconds)
        let commands = Set(output.split(separator: "\n").map(String.init))
        return detect(commands: commands)
    }

    private static func runProbe(
        home: MSLHome, name: String, timeoutSeconds: Int
    ) throws -> String {
        let probe = supported.map { "command -v \($0.command) >/dev/null && echo \($0.command)" }
            .joined(separator: "; ")
        let script = probe + "; exit 0"
        let exe = SpawnDaemon.selfExecutablePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["run", name, "--", "/bin/sh", "-lc", script]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["MSL_HOME": home.root.path]
        ) { _, new in new }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw MSLError.timedOut("desktop probe exceeded \(timeoutSeconds)s")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw MSLError.configuration(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
