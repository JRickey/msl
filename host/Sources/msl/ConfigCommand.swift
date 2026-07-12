import ArgumentParser
import Foundation
import MSLCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change per-distro settings (user, mac-share, hostname, rosetta, gpu).",
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

    @Option(
        name: .customLong("rosetta"),
        help: """
            x86-64 translation: on | off. Takes effect on the next distro boot. \
            If the host lacks Rosetta, run 'softwareupdate --install-rosetta'.
            """)
    var rosetta: String?

    @Option(
        name: .customLong("gpu"),
        help: """
            GPU passthrough: on | off. Requires the krun backend (milestone G3), \
            which is not available yet, so 'on' is rejected. Mutually exclusive \
            with rosetta.
            """)
    var gpu: String?

    func run() throws {
        assert(!name.isEmpty, "distro name argument must not be empty")
        let home = MSLHome.resolve()
        let store = RegistryStore(home: home)
        let registry: Registry
        if hasChanges {
            registry = try store.update { current in
                try requireEntry(current)
                let changed = try applySetters(&current)
                assert(changed, "a mutation transaction must apply at least one setter")
            }
        } else {
            registry = try store.load()
            try requireEntry(registry)
        }
        try printEntry(registry)
    }

    private var hasChanges: Bool {
        hostname != nil || defaultUser != nil || macShare != nil || rosetta != nil || gpu != nil
    }

    private func requireEntry(_ registry: Registry) throws {
        assert(!name.isEmpty, "distro name must not be empty")
        guard registry.entry(name: name) != nil else {
            throw MSLError.invalidArgument("no such distro: \(name) (see 'msl list')")
        }
    }

    private func applySetters(_ registry: inout Registry) throws -> Bool {
        assert(!name.isEmpty, "distro name must not be empty")
        // Cross-validate gpu/rosetta before any setter mutates, so a rejected
        // combination (or an attempt to enable the still-unbuilt GPU backend)
        // persists nothing — the transaction aborts on the throw.
        try validateGpuRosetta(registry)
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
        if let rosetta {
            try registry.setRosetta(name: name, on: Self.parseRosetta(rosetta))
            changed = true
        }
        if let gpu {
            try registry.setGpu(name: name, on: Self.parseGpu(gpu))
            changed = true
        }
        return changed
    }

    /// Fold this invocation's `--gpu`/`--rosetta` flags over the distro's stored
    /// values and reject an unsupportable result. `requireEntry` has already run,
    /// so the entry is present; the guard is a belt against a future reorder. The
    /// krun-availability rejection fires only when this invocation enables GPU.
    private func validateGpuRosetta(_ registry: Registry) throws {
        guard let entry = registry.entry(name: name) else { return }
        let gpuOn = try gpu.map(Self.parseGpu) ?? (entry.gpu ?? false)
        let rosettaOn = try rosetta.map(Self.parseRosetta) ?? (entry.rosetta ?? false)
        try Registry.validateGpuRosetta(
            gpuOn: gpuOn, rosettaOn: rosettaOn, enablingGpu: gpu != nil && gpuOn)
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

    private static func parseRosetta(_ value: String) throws -> Bool {
        switch value {
        case "on": return true
        case "off": return false
        default:
            throw MSLError.invalidArgument("--rosetta must be on|off, got: \(value)")
        }
    }

    private static func parseGpu(_ value: String) throws -> Bool {
        switch value {
        case "on": return true
        case "off": return false
        default:
            throw MSLError.invalidArgument("--gpu must be on|off, got: \(value)")
        }
    }

    private func printEntry(_ registry: Registry) throws {
        guard let entry = registry.entry(name: name) else {
            throw MSLError.invalidArgument("no such distro: \(name)")
        }
        assert(entry.name == name, "printed entry must match the requested name")
        let user = entry.defaultUser ?? "root (unset)"
        let share = entry.macShare.map { $0 ? "on" : "off" } ?? "inherit"
        let rosetta = (entry.rosetta ?? false) ? "on" : "off"
        let gpu = (entry.gpu ?? false) ? "on" : "off"
        print("name:          \(entry.name)")
        print("hostname:      \(entry.hostname)")
        print("default user:  \(user)")
        print("mac-share:     \(share)")
        print("rosetta:       \(rosetta)")
        print("gpu:           \(gpu)")
        print("image:         \(entry.image)")
        print("created:       \(entry.createdAt)")
    }
}
