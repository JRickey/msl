import Foundation
import MSLCore

/// One snapshot of daemon reality gathered off the main thread: whether the
/// socket answered, the status reply (nil when it did not), and the registry's
/// default distro (the status RPC omits it, so it is read from disk separately).
public struct DaemonProbe: Equatable, Sendable {
    public let running: Bool
    public let status: StatusData?
    public let defaultDistro: String?

    public init(running: Bool, status: StatusData?, defaultDistro: String?) {
        self.running = running
        self.status = status
        self.defaultDistro = defaultDistro
    }
}

/// Pure projection of a `DaemonProbe` into the rows and enabled-state the menu
/// renders. Kept AppKit-free so the mapping is unit-tested without a UI.
public struct MenuModel: Equatable, Sendable {
    public enum Daemon: Equatable, Sendable {
        case running
        case stopped
    }

    public struct DistroRow: Equatable, Sendable {
        public let name: String
        public let state: String
        public let sessions: Int
        public let isDefault: Bool

        public init(name: String, state: String, sessions: Int, isDefault: Bool) {
            self.name = name
            self.state = state
            self.sessions = sessions
            self.isDefault = isDefault
        }
    }

    public let daemon: Daemon
    public let vm: String?
    public let distros: [DistroRow]

    public init(daemon: Daemon, vm: String?, distros: [DistroRow]) {
        self.daemon = daemon
        self.vm = vm
        self.distros = distros
    }

    /// Project a probe: a live status supplies the VM string and distro rows
    /// (default marked from the registry name); anything else is the stopped
    /// model with no VM line and no rows.
    public static func make(probe: DaemonProbe) -> MenuModel {
        guard probe.running, let status = probe.status else {
            return MenuModel(daemon: .stopped, vm: nil, distros: [])
        }
        let rows = status.distros.map { entry in  // bounded: registry list
            DistroRow(
                name: entry.name, state: entry.state, sessions: entry.sessions,
                isDefault: entry.name == probe.defaultDistro)
        }
        assert(rows.count == status.distros.count, "one row per distro")
        assert(!status.vm.isEmpty, "a running daemon reports a VM state")
        return MenuModel(daemon: .running, vm: status.vm, distros: rows)
    }

    public var daemonTitle: String {
        return daemon == .running ? "Subsystem: running" : "Subsystem: not running"
    }

    /// The VM-state line, present only when the daemon answered.
    public var vmTitle: String? {
        guard let vm else { return nil }
        assert(!vm.isEmpty, "vm state string is non-empty when present")
        return "VM: \(vm)"
    }

    public var startEnabled: Bool { daemon == .stopped }
    public var shutDownEnabled: Bool { daemon == .running }
}
