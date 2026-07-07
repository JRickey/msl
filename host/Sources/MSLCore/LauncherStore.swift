import Foundation

public enum LauncherMode: String, Codable, CaseIterable, Sendable {
    case auto
    case shell
    case desktop
}

public struct LauncherRecord: Codable, Equatable, Sendable {
    public let schema: Int
    public let kind: String
    public let distro: String
    public let launchMode: LauncherMode
    public let createdBy: String

    public init(distro: String, launchMode: LauncherMode) {
        precondition(!distro.isEmpty, "launcher distro must not be empty")
        self.schema = 1
        self.kind = "distro"
        self.distro = distro
        self.launchMode = launchMode
        self.createdBy = "msl"
    }

    public var isOwnedDistro: Bool {
        return schema == 1 && kind == "distro" && createdBy == "msl"
    }
}

public struct LauncherManifestRecord: Codable, Equatable, Sendable {
    public let distro: String
    public let path: String
    public let launchMode: LauncherMode
}

public struct LauncherRow: Equatable, Sendable {
    public let distro: String
    public let path: String
    public let launchMode: LauncherMode?
    public let exists: Bool
}

public struct LauncherStore: Sendable {
    private let home: MSLHome
    private let applicationsDirectory: URL
    private let mslExecutable: String
    private let signBundles: Bool

    public init(
        home: MSLHome,
        applicationsDirectory: URL = LauncherStore.defaultApplicationsDirectory(),
        mslExecutable: String = SpawnDaemon.selfExecutablePath(),
        signBundles: Bool = true
    ) {
        self.home = home
        self.applicationsDirectory = applicationsDirectory
        self.mslExecutable = mslExecutable
        self.signBundles = signBundles
    }

    public static func defaultApplicationsDirectory(
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = env["MSL_APPLICATIONS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let applications = homeDirectory.appendingPathComponent("Applications")
        if pathExistsAsFile(applications) {
            return homeDirectory.appendingPathComponent(".msl").appendingPathComponent(
                "Applications")
        }
        return applications.appendingPathComponent("msl")
    }

    private static func pathExistsAsFile(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    @discardableResult
    public func create(
        name: String, mode: LauncherMode, replace: Bool, icon: URL? = nil
    ) throws -> URL {
        try validateRegistered(name)
        let app = appURL(name: name)
        if FileManager.default.fileExists(atPath: app.path) {
            try validateOwned(app: app, distro: name)
            guard replace else {
                throw MSLError.configuration("launcher already exists: \(app.path)")
            }
        }
        let temp = applicationsDirectory.appendingPathComponent(".\(name).\(UUID().uuidString).app")
        try? FileManager.default.removeItem(at: temp)
        try writeBundle(temp, name: name, mode: mode, icon: icon)
        if signBundles { try sign(app: temp) }
        try replaceItem(temp, app)
        try upsertManifest(name: name, mode: mode, path: app.path)
        return app
    }

    public func remove(name: String) throws {
        let app = appURL(name: name)
        if FileManager.default.fileExists(atPath: app.path) {
            try validateOwned(app: app, distro: name)
            try FileManager.default.removeItem(at: app)
        }
        try removeManifest(name: name)
    }

    public func rows(registry: Registry) throws -> [LauncherRow] {
        let manifest = try loadManifest()
        return registry.distros.map { entry in
            let record = manifest.records.first { $0.distro == entry.name }
            let path = record?.path ?? appURL(name: entry.name).path
            return LauncherRow(
                distro: entry.name, path: path, launchMode: record?.launchMode,
                exists: FileManager.default.fileExists(atPath: path))
        }
    }

    public func appURL(name: String) -> URL {
        precondition(Registry.isValidName(name), "launcher names are registry names")
        return applicationsDirectory.appendingPathComponent(name + ".app")
    }

    public func record(in app: URL) throws -> LauncherRecord {
        let url = app.appendingPathComponent("Contents/Resources/launcher.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LauncherRecord.self, from: data)
    }

    public func open(name: String) throws {
        try validateRegistered(name)
        let app = appURL(name: name)
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw MSLError.configuration("launcher missing: \(app.path)")
        }
        try runProcess("/usr/bin/open", [app.path])
    }

    public func reveal(name: String) throws {
        let app = appURL(name: name)
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw MSLError.configuration("launcher missing: \(app.path)")
        }
        try runProcess("/usr/bin/open", ["-R", app.path])
    }

    private func validateRegistered(_ name: String) throws {
        guard Registry.isValidName(name) else {
            throw MSLError.invalidArgument("invalid distro name: \(name)")
        }
        guard try Registry.load(from: home.registryURL).entry(name: name) != nil else {
            throw MSLError.invalidArgument("no such distro: \(name)")
        }
    }

    private func validateOwned(app: URL, distro: String) throws {
        let rec = try record(in: app)
        guard rec.isOwnedDistro, rec.distro == distro else {
            throw MSLError.configuration("refusing to replace non-msl launcher: \(app.path)")
        }
    }

    private func writeBundle(
        _ app: URL, name: String, mode: LauncherMode, icon: URL?
    ) throws {
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try writeInfoPlist(app: app, name: name)
        try writeRecord(resources: resources, name: name, mode: mode)
        try writeIcon(resources: resources, name: name, icon: icon)
        try writeScript(macOS: macOS)
    }

    private func writeInfoPlist(app: URL, name: String) throws {
        let dict: [String: Any] = [
            "CFBundleExecutable": "msl-launcher",
            "CFBundleIdentifier": "dev.msl.launcher.distro.\(name)",
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": LauncherIcon.bundleIconName,
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    private func writeRecord(resources: URL, name: String, mode: LauncherMode) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LauncherRecord(distro: name, launchMode: mode))
        try data.write(to: resources.appendingPathComponent("launcher.json"))
    }

    private func writeIcon(resources: URL, name: String, icon: URL?) throws {
        let target = resources.appendingPathComponent(LauncherIcon.bundleIconName + ".icns")
        if let icon {
            guard FileManager.default.isReadableFile(atPath: icon.path) else {
                throw MSLError.io("cannot read icon \(icon.path)")
            }
            try LauncherIcon.validateICNS(at: icon)
            try FileManager.default.copyItem(at: icon, to: target)
            return
        }
        try LauncherIcon.writeFallbackICNS(name: name, to: target)
    }

    private func writeScript(macOS: URL) throws {
        let script = """
            #!/bin/sh
            APP_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
            export MSL_HOME=\(Self.shellQuote(home.root.path))
            MSL_EXE=\(Self.shellQuote(mslExecutable))
            if [ ! -x "$MSL_EXE" ]; then
              MSL_EXE="$(command -v msl 2>/dev/null || true)"
            fi
            if [ ! -x "$MSL_EXE" ]; then
              /usr/bin/osascript -e 'display alert "msl launcher failed" message "Cannot find the msl executable."'
              exit 1
            fi
            exec "$MSL_EXE" launcher run-bundle "$APP_DIR"
            """
        let url = macOS.appendingPathComponent("msl-launcher")
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func replaceItem(_ source: URL, _ destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func sign(app: URL) throws {
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    }

    private func runProcess(_ executable: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MSLError.io("\(executable) failed with status \(process.terminationStatus)")
        }
    }

    private func loadManifest() throws -> LauncherManifest {
        guard FileManager.default.fileExists(atPath: home.launchersURL.path) else {
            return LauncherManifest()
        }
        let data = try Data(contentsOf: home.launchersURL)
        return try JSONDecoder().decode(LauncherManifest.self, from: data)
    }

    private func saveManifest(_ manifest: LauncherManifest) throws {
        try home.ensureDirectories()
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: home.launchersURL, options: .atomic)
    }

    private func upsertManifest(name: String, mode: LauncherMode, path: String) throws {
        var manifest = try loadManifest()
        manifest.records.removeAll { $0.distro == name }
        manifest.records.append(LauncherManifestRecord(distro: name, path: path, launchMode: mode))
        try saveManifest(manifest)
    }

    private func removeManifest(name: String) throws {
        var manifest = try loadManifest()
        manifest.records.removeAll { $0.distro == name }
        try saveManifest(manifest)
    }

    public static func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct LauncherManifest: Codable, Equatable {
    var schema: Int = 1
    var records: [LauncherManifestRecord] = []
}
