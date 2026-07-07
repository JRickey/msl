import ArgumentParser
import Foundation
import MSLCore

struct CatalogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "List catalog distros available for install.",
        subcommands: [CatalogListCommand.self, CatalogShowCommand.self])
}

struct CatalogListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List catalog distros available for install.")

    @Flag(name: .long, help: "Include experimental entries.")
    var all = false

    func run() throws {
        let rows = try Catalog.loadEmbedded().listRows(includeExperimental: all)
        guard !rows.isEmpty else {
            print("no catalog distros available")
            return
        }
        let nameWidth = maxWidth(header: "NAME", rows.map(\.name)) + 2
        let versionWidth = maxWidth(header: "VERSION", rows.map(\.version)) + 2
        let statusWidth = maxWidth(header: "STATUS", rows.map { $0.status.rawValue }) + 2
        print(
            pad("NAME", nameWidth) + pad("VERSION", versionWidth) + pad("STATUS", statusWidth)
                + "DESCRIPTION")
        for row in rows {  // bounded: embedded catalog
            let line =
                pad(row.name, nameWidth) + pad(row.version, versionWidth)
                + pad(row.status.rawValue, statusWidth) + row.description
            print(line)
        }
    }

    private func maxWidth(header: String, _ values: [String]) -> Int {
        let valueWidth = values.map(\.count).max() ?? 0
        return max(header.count, valueWidth)
    }

    private func pad(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }
}

struct CatalogShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one catalog distro entry.")

    @Argument(help: "Catalog selector, such as ubuntu or ubuntu@24.04.")
    var selector: String

    func run() throws {
        let resolved = try Catalog.loadEmbedded().resolve(selector: selector)
        print("Name:        \(resolved.family.name)")
        print("Version:     \(resolved.version.version)")
        print("Status:      \(resolved.version.status.rawValue)")
        print("Description: \(resolved.version.notes)")
        print("Size:        \(Self.humanBytes(resolved.artifact.sizeBytes)) download")
        print("SHA256:      \(resolved.artifact.sha256)")
        print("URL:         \(resolved.artifact.url)")
        print("Install:     msl install \(resolved.selector)")
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {  // bounded: units.count
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f%@" : "%.1f%@", value, units[unit])
    }
}
