import ArgumentParser
import Foundation
import MSLCore

struct LauncherCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launcher",
        abstract: "Manage macOS app launchers for installed distros.",
        subcommands: [
            LauncherListCommand.self, LauncherCreateCommand.self, LauncherRemoveCommand.self,
            LauncherRefreshCommand.self, LauncherRevealCommand.self, LauncherOpenCommand.self,
            LauncherRunBundleCommand.self,
        ])
}

struct LauncherListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")

    func run() throws {
        let home = MSLHome.resolve()
        let registry = try Registry.load(from: home.registryURL)
        let rows = try LauncherStore(home: home).rows(registry: registry)
        print("DISTRO             MODE       STATE      PATH")
        for row in rows {  // bounded: registry list
            let mode = row.launchMode?.rawValue ?? "-"
            let state = row.exists ? "present" : "missing"
            print(pad(row.distro, 19) + pad(mode, 11) + pad(state, 11) + row.path)
        }
    }

    private func pad(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }
}

struct LauncherCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create")

    @Argument(help: "Installed distro name.")
    var name: String

    @Option(name: .long, help: "Launch mode: shell, auto, or desktop.")
    var mode: LauncherMode = .shell

    @Flag(name: .long, help: "Replace an existing msl-owned launcher.")
    var replace = false

    func run() throws {
        let home = MSLHome.resolve()
        let icon = try LauncherIconResolver(home: home).icon(for: name)
        let url = try LauncherStore(home: home).create(
            name: name, mode: mode, replace: replace, icon: icon)
        print("created \(url.path)")
    }
}

struct LauncherRefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "refresh")

    @Argument(help: "Installed distro name.")
    var name: String

    @Option(name: .long, help: "Launch mode: shell, auto, or desktop.")
    var mode: LauncherMode = .shell

    func run() throws {
        let home = MSLHome.resolve()
        let icon = try LauncherIconResolver(home: home).icon(for: name)
        let url = try LauncherStore(home: home).create(
            name: name, mode: mode, replace: true, icon: icon)
        print("refreshed \(url.path)")
    }
}

struct LauncherRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove")

    @Argument(help: "Installed distro name.")
    var name: String

    func run() throws {
        try LauncherStore(home: MSLHome.resolve()).remove(name: name)
        print("removed launcher for \(name)")
    }
}

struct LauncherRevealCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reveal")

    @Argument(help: "Installed distro name.")
    var name: String

    func run() throws {
        try LauncherStore(home: MSLHome.resolve()).reveal(name: name)
    }
}

struct LauncherOpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open")

    @Argument(help: "Installed distro name.")
    var name: String

    func run() throws {
        try LauncherStore(home: MSLHome.resolve()).open(name: name)
    }
}

struct LauncherRunBundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run-bundle", shouldDisplay: false)

    @Argument(help: "Launcher app bundle path.")
    var path: String

    func run() throws {
        try LauncherRuntime.runBundle(URL(fileURLWithPath: path), home: MSLHome.resolve())
    }
}

extension LauncherMode: ExpressibleByArgument {}

private struct LauncherIconResolver {
    private let home: MSLHome

    init(home: MSLHome) {
        self.home = home
    }

    func icon(for name: String) throws -> URL? {
        let registry = try Registry.load(from: home.registryURL)
        guard let entry = registry.entry(name: name) else { return nil }
        let catalog = try? Catalog.loadEmbedded()
        if let selector = entry.catalogSelector {
            if let icon = try icon(for: selector, catalog: catalog) {
                return icon
            }
        }
        if let icon = try icon(for: entry.name, catalog: catalog) {
            return icon
        }
        guard let known = DistroIconCatalog.icon(for: entry.name) else {
            note("launcher: no catalog icon; generating fallback icon")
            return nil
        }
        note("launcher: preparing \(entry.name) icon")
        return try CatalogIconStore(home: home).icon(known, label: entry.name) { progress in
            Self.emit(progress)
        }
    }

    private func icon(for selector: String, catalog: Catalog?) throws -> URL? {
        guard let resolved = try? catalog?.resolve(selector: selector) else { return nil }
        return try icon(for: resolved)
    }

    private func icon(for resolved: CatalogResolved) throws -> URL? {
        guard resolved.version.icon != nil else { return nil }
        note("launcher: preparing \(resolved.family.name) icon")
        return try CatalogIconStore(home: home).icon(for: resolved) { progress in
            Self.emit(progress)
        }
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func emit(_ progress: CatalogDownloadProgress) {
        switch progress {
        case .checkingCache(let path):
            note("launcher: checking icon cache \(path)")
        case .cacheHit(let path):
            note("launcher: icon cache hit; SHA256 already verified at \(path)")
        case .startingDownload(let url, let bytes):
            note("launcher: downloading icon \(url) (\(humanBytes(bytes)))")
        case .downloading:
            return
        case .verifying(_, let sha256):
            note("launcher: verifying icon SHA256 \(sha256)")
        case .ready(let path):
            note("launcher: icon ready at \(path)")
        }
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f%@" : "%.1f%@", value, units[unit])
    }
}
