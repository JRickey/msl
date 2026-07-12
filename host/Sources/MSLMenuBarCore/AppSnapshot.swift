import Foundation
import MSLCore

public enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    case distros = "Distros"
    case storage = "Storage"
    case networking = "Networking"
    case integrations = "Integrations"
    case privacy = "Privacy & Security"
    case diagnostics = "Diagnostics"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .distros: "shippingbox"
        case .storage: "internaldrive"
        case .networking: "network"
        case .integrations: "puzzlepiece.extension"
        case .privacy: "lock.shield"
        case .diagnostics: "stethoscope"
        }
    }
}

public struct AppInventoryItem: Equatable, Sendable {
    public let name: String
    public let hostname: String
    public let defaultUser: String?
    public let macShare: Bool?
    public let rosetta: Bool
    public let createdAt: String
    public let catalogSelector: String?
    public let allocatedBytes: UInt64?
    public let capacityBytes: UInt64?
    public let finderPath: String?

    public init(
        name: String, hostname: String, defaultUser: String?, macShare: Bool?, rosetta: Bool,
        createdAt: String, catalogSelector: String?, allocatedBytes: UInt64?,
        capacityBytes: UInt64?, finderPath: String?
    ) {
        precondition(!name.isEmpty, "inventory name must not be empty")
        precondition(!hostname.isEmpty, "inventory hostname must not be empty")
        self.name = name
        self.hostname = hostname
        self.defaultUser = defaultUser
        self.macShare = macShare
        self.rosetta = rosetta
        self.createdAt = createdAt
        self.catalogSelector = catalogSelector
        self.allocatedBytes = allocatedBytes
        self.capacityBytes = capacityBytes
        self.finderPath = finderPath
    }
}

public struct AppInventory: Equatable, Sendable {
    public let defaultDistro: String?
    public let distros: [AppInventoryItem]

    public init(defaultDistro: String?, distros: [AppInventoryItem]) {
        self.defaultDistro = defaultDistro
        self.distros = distros
    }
}

public struct AppDistroSnapshot: Equatable, Identifiable, Sendable {
    public let inventory: AppInventoryItem
    public let state: String
    public let sessions: Int

    public var id: String { inventory.name }
    public var name: String { inventory.name }
    public var isRunning: Bool { state == "running" }
    public var finderAvailable: Bool { inventory.finderPath != nil }

    public func storageLabel(_ value: UInt64?) -> String {
        guard let value else { return "Not available" }
        return IECByteFormatter.string(from: value)
    }
}

public enum FinderSetupState: Equatable, Sendable {
    case checking
    case disabled
    case ready
    case restartRequired

    public func refreshed(enabled: Bool) -> FinderSetupState {
        if self == .restartRequired { return .restartRequired }
        return enabled ? .ready : .disabled
    }
}

public struct AppSnapshot: Equatable, Sendable {
    public let daemonRunning: Bool
    public let vmState: String
    public let defaultDistro: String?
    public let distros: [AppDistroSnapshot]
    public let forwardedPorts: [UInt16]

    public init(inventory: AppInventory, status: StatusData?) {
        let runtimeByName = Dictionary(
            uniqueKeysWithValues: (status?.distros ?? []).map { ($0.name, $0) })
        self.daemonRunning = status != nil
        self.vmState = status?.vm ?? "stopped"
        self.defaultDistro = inventory.defaultDistro
        self.distros = inventory.distros.map { item in
            let runtime = runtimeByName[item.name]
            return AppDistroSnapshot(
                inventory: item, state: runtime?.state ?? "stopped",
                sessions: runtime?.sessions ?? 0)
        }
        self.forwardedPorts = status?.forwardedPorts ?? []
        assert(distros.count == inventory.distros.count, "projection preserves inventory rows")
        assert(!vmState.isEmpty, "VM state must be displayable")
    }

    public static let empty = AppSnapshot(
        inventory: AppInventory(defaultDistro: nil, distros: []), status: nil)

    public func selectedName(preserving current: String?) -> String? {
        if let current, distros.contains(where: { $0.name == current }) { return current }
        if let defaultDistro, distros.contains(where: { $0.name == defaultDistro }) {
            return defaultDistro
        }
        return distros.first?.name
    }

    public func distro(named name: String?) -> AppDistroSnapshot? {
        guard let name else { return nil }
        return distros.first { $0.name == name }
    }
}
