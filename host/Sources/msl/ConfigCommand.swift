import ArgumentParser
import Foundation
import MSLCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change per-distro settings (default user, mac-share, hostname).",
        discussion: """
            With no options, prints the distro's current settings. Hostname and \
            mac-share changes take effect on the next distro boot — run 'msl stop' \
            first if it is running. Default-user changes apply to new shells.
            """)

    @Argument(help: "Distro name.")
    var name: String

    @Option(name: .long, help: "Set the hostname (^[a-z0-9][a-z0-9-]{0,63}$).")
    var hostname: String?

    @Option(name: .customLong("default-user"), help: "Login user for shells; 'root' or '' clears.")
    var defaultUser: String?

    @Option(name: .customLong("mac-share"), help: "Mac home sharing: on | off | inherit.")
    var macShare: String?

    func run() throws {
        assert(!name.isEmpty, "distro name argument must not be empty")
        let home = MSLHome.resolve()
        var registry = try Registry.load(from: home.registryURL)
        guard registry.entry(name: name) != nil else {
            throw MSLError.invalidArgument("no such distro: \(name) (see 'msl list')")
        }
        let changed = try applySetters(&registry)
        if changed { try registry.save(to: home.registryURL) }
        try printEntry(registry)
    }

    private func applySetters(_ registry: inout Registry) throws -> Bool {
        assert(!name.isEmpty, "distro name must not be empty")
        var changed = false
        if let hostname {
            try registry.setHostname(name: name, hostname: hostname)
            changed = true
        }
        if let defaultUser {
            let user = (defaultUser.isEmpty || defaultUser == "root") ? nil : defaultUser
            try registry.setDefaultUser(name: name, user: user)
            changed = true
        }
        if let macShare {
            try registry.setMacShare(name: name, share: Self.parseMacShare(macShare))
            changed = true
        }
        return changed
    }

    private static func parseMacShare(_ value: String) throws -> Bool? {
        switch value {
        case "on": return true
        case "off": return false
        case "inherit": return nil
        default:
            throw MSLError.invalidArgument("--mac-share must be on|off|inherit, got: \(value)")
        }
    }

    private func printEntry(_ registry: Registry) throws {
        guard let entry = registry.entry(name: name) else {
            throw MSLError.invalidArgument("no such distro: \(name)")
        }
        assert(entry.name == name, "printed entry must match the requested name")
        let user = entry.defaultUser ?? "root (unset)"
        let share = entry.macShare.map { $0 ? "on" : "off" } ?? "inherit"
        print("name:          \(entry.name)")
        print("hostname:      \(entry.hostname)")
        print("default user:  \(user)")
        print("mac-share:     \(share)")
        print("image:         \(entry.image)")
        print("created:       \(entry.createdAt)")
    }
}
