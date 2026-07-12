import Foundation
import MSLCore

public enum MacShareChoice: String, CaseIterable, Identifiable, Sendable {
    case inherit = "Inherit"
    case on = "On"
    case off = "Off"

    public var id: String { rawValue }

    public init(value: Bool?) {
        switch value {
        case true: self = .on
        case false: self = .off
        case nil: self = .inherit
        }
    }

    public var value: Bool? {
        switch self {
        case .inherit: nil
        case .on: true
        case .off: false
        }
    }
}

public struct DistroSettingsDraft: Equatable, Sendable {
    public var name: String
    public var hostname: String
    public var defaultUser: String
    public var macShare: MacShareChoice
    public var rosetta: Bool
    public var isDefault: Bool

    public init(distro: AppDistroSnapshot?, defaultDistro: String?) {
        self.name = distro?.name ?? ""
        self.hostname = distro?.inventory.hostname ?? ""
        self.defaultUser = distro?.inventory.defaultUser ?? "root"
        self.macShare = MacShareChoice(value: distro?.inventory.macShare)
        self.rosetta = distro?.inventory.rosetta ?? false
        self.isDefault = distro?.name == defaultDistro
    }

    public var normalizedUser: String? {
        let trimmed = defaultUser.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "root" ? nil : trimmed
    }

    public var validationError: String? {
        guard Registry.isValidHostname(hostname) else {
            return "Hostname must use lowercase letters, numbers, and hyphens."
        }
        if let user = normalizedUser, !Registry.isValidUser(user) {
            return "Default user must be a valid Linux user name."
        }
        return nil
    }

    public func changes(
        from distro: AppDistroSnapshot, defaultDistro: String?
    ) -> DistroSettingsChanges {
        precondition(distro.name == name, "draft must match its distro")
        let defaultChanged = isDefault && defaultDistro != name
        return DistroSettingsChanges(
            hostname: hostname != distro.inventory.hostname,
            defaultUser: normalizedUser != distro.inventory.defaultUser,
            macShare: macShare.value != distro.inventory.macShare,
            rosetta: rosetta != distro.inventory.rosetta,
            defaultDistro: defaultChanged)
    }
}

public struct DistroSettingsChanges: Equatable, Sendable {
    public let hostname: Bool
    public let defaultUser: Bool
    public let macShare: Bool
    public let rosetta: Bool
    public let defaultDistro: Bool

    public var isEmpty: Bool {
        !hostname && !defaultUser && !macShare && !rosetta && !defaultDistro
    }

    public var requiresDistroRestart: Bool { hostname || macShare }
    public var requiresSubsystemRestart: Bool { rosetta }

    public func apply(draft: DistroSettingsDraft, to registry: inout Registry) throws {
        if hostname { try registry.setHostname(name: draft.name, hostname: draft.hostname) }
        if defaultUser {
            try registry.setDefaultUser(name: draft.name, user: draft.normalizedUser)
        }
        if macShare { try registry.setMacShare(name: draft.name, share: draft.macShare.value) }
        if rosetta { try registry.setRosetta(name: draft.name, on: draft.rosetta) }
        if defaultDistro { try registry.setDefault(name: draft.name) }
    }
}

public struct HostSettingsChanges: Equatable, Sendable {
    public let cpuCount: Bool
    public let memoryMiB: Bool
    public let idleTimeout: Bool
    public let shareHome: Bool
    public let interop: Bool

    public init(draft: HostSettingsDraft, baseline: MSLHostSettings) throws {
        let desired = try draft.settings()
        self.cpuCount = desired.cpuCount != baseline.cpuCount
        self.memoryMiB = desired.memoryMiB != baseline.memoryMiB
        self.idleTimeout = desired.idleTimeoutS != baseline.idleTimeoutS
        self.shareHome = desired.shareHome != baseline.shareHome
        self.interop = desired.interopEnabled != baseline.interopEnabled
    }

    public var isEmpty: Bool {
        !cpuCount && !memoryMiB && !idleTimeout && !shareHome && !interop
    }

    public func apply(draft: HostSettingsDraft, to settings: inout MSLHostSettings) throws {
        let desired = try draft.settings()
        if cpuCount { settings.cpuCount = desired.cpuCount }
        if memoryMiB { settings.memoryMiB = desired.memoryMiB }
        if idleTimeout { settings.idleTimeoutS = desired.idleTimeoutS }
        if shareHome { settings.shareHome = desired.shareHome }
        if interop { settings.interopEnabled = desired.interopEnabled }
    }
}

public struct HostSettingsDraft: Equatable, Sendable {
    public var automaticCPU: Bool
    public var cpuCount: Int
    public var automaticMemory: Bool
    public var memoryMiB: UInt64
    public var idleTimeoutS: Int
    public var shareHome: Bool
    public var interopEnabled: Bool
    public let cpuUpperBound: Int
    public let memoryUpperBoundMiB: UInt64

    public init(settings: MSLHostSettings, facts: SharedVMHardwareFacts) {
        let automatic = SharedVMSizing.resolve(for: facts)
        self.automaticCPU = settings.cpuCount == nil
        self.cpuCount = settings.cpuCount ?? automatic.cpuCount
        self.automaticMemory = settings.memoryMiB == nil
        self.memoryMiB = settings.memoryMiB ?? automatic.memoryMiB
        self.idleTimeoutS = settings.idleTimeoutS
        self.shareHome = settings.shareHome
        self.interopEnabled = settings.interopEnabled
        self.cpuUpperBound = min(64, max(settings.cpuCount ?? 1, facts.activeCPUCount))
        self.memoryUpperBoundMiB = min(
            65_536, max(settings.memoryMiB ?? 1024, facts.physicalMemoryMiB))
    }

    public static let placeholder = HostSettingsDraft(
        settings: MSLHostSettings(),
        facts: SharedVMHardwareFacts(
            activeCPUCount: 1, performanceCoreCount: nil, physicalMemoryMiB: 4096))

    public var validationError: String? {
        if !automaticCPU, !(1...64).contains(cpuCount) { return "CPU count must be 1...64." }
        if !automaticMemory, !(1024...65_536).contains(memoryMiB) {
            return "Memory must be 1024...65536 MiB."
        }
        if !(0...86_400).contains(idleTimeoutS) {
            return "Idle timeout must be 0...86400 seconds."
        }
        return nil
    }

    public func settings() throws -> MSLHostSettings {
        guard let validationError else {
            return MSLHostSettings(
                cpuCount: automaticCPU ? nil : cpuCount,
                memoryMiB: automaticMemory ? nil : memoryMiB,
                idleTimeoutS: idleTimeoutS, shareHome: shareHome,
                interopEnabled: interopEnabled)
        }
        throw MSLError.configuration(validationError)
    }
}

public struct AppOverviewSnapshot: Equatable, Sendable {
    public let daemonRunning: Bool
    public let vmState: String
    public let memory: MemoryStatus?
    public let installedDistros: Int
    public let runningDistros: Int
    public let liveSessions: Int
    public let forwardedPorts: [UInt16]

    public init(snapshot: AppSnapshot) {
        self.daemonRunning = snapshot.daemonRunning
        self.vmState = snapshot.vmState
        self.memory = snapshot.memory
        self.installedDistros = snapshot.distros.count
        self.runningDistros = snapshot.distros.filter(\.isRunning).count
        self.liveSessions = snapshot.distros.reduce(0) { $0 + $1.sessions }
        self.forwardedPorts = snapshot.forwardedPorts
        assert(runningDistros <= installedDistros, "running distros must be installed")
        assert(liveSessions >= 0, "session count must be non-negative")
    }
}

public enum RestartScope: Equatable, Hashable, Sendable {
    case subsystem
    case distro(String)
}

public enum PendingRefreshPolicy: Equatable, Sendable {
    case reconcileStopped
    case preserve
}

public enum LifecyclePendingEffect: Equatable, Sendable {
    case distroRestart(String)
    case distroStop(String)
    case subsystemRestart
    case subsystemStart
    case subsystemStop
}

public struct PendingRestarts: Equatable, Sendable {
    private var scopes: Set<RestartScope> = []

    public init() {}

    public func contains(_ scope: RestartScope) -> Bool { scopes.contains(scope) }

    public mutating func mark(_ scope: RestartScope) {
        if case .distro(let name) = scope { precondition(Registry.isValidName(name)) }
        scopes.insert(scope)
    }

    public mutating func clear(_ scope: RestartScope) {
        scopes.remove(scope)
    }

    public mutating func clearDistros() {
        scopes = scopes.filter {
            if case .distro = $0 { return false }
            return true
        }
    }

    public mutating func recordDistroSave(
        name: String, distroActive: Bool, vmActive: Bool, changes: DistroSettingsChanges
    ) {
        precondition(Registry.isValidName(name))
        if distroActive, changes.requiresDistroRestart { mark(.distro(name)) }
        if vmActive, changes.requiresSubsystemRestart { mark(.subsystem) }
    }

    public mutating func recordHostSave(active: Bool) {
        if active { mark(.subsystem) }
    }

    public mutating func recordLifecycle(
        _ outcome: LifecycleOutcome, effect: LifecyclePendingEffect
    ) {
        guard case .succeeded = outcome else { return }
        switch effect {
        case .distroRestart(let name), .distroStop(let name):
            precondition(Registry.isValidName(name))
            clear(.distro(name))
        case .subsystemRestart, .subsystemStop:
            scopes.removeAll()
        case .subsystemStart:
            clear(.subsystem)
        }
    }

    public mutating func reconcile(snapshot: AppSnapshot, policy: PendingRefreshPolicy) {
        guard policy == .reconcileStopped else { return }
        if snapshot.vmState == "stopped" {
            scopes.removeAll()
            return
        }
        scopes = scopes.filter { scope in
            guard case .distro(let name) = scope else { return true }
            return snapshot.distro(named: name)?.isRunning == true
        }
    }
}

public enum LifecycleOutcome: Equatable, Sendable {
    case succeeded
    case failed(message: String)

    public var needsRefresh: Bool {
        true
    }

    public var pendingRefreshPolicy: PendingRefreshPolicy {
        switch self {
        case .succeeded: .reconcileStopped
        case .failed: .preserve
        }
    }
}
