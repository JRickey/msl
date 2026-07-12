import Darwin
import Foundation

public struct DistroStorageMetrics: Sendable, Equatable {
    public let imagePresent: Bool
    public let allocatedBytes: UInt64
    public let capacityBytes: UInt64

    public init(imagePresent: Bool, allocatedBytes: UInt64, capacityBytes: UInt64) {
        precondition(imagePresent || allocatedBytes == 0, "a missing image has no allocation")
        precondition(imagePresent || capacityBytes == 0, "a missing image has no capacity")
        self.imagePresent = imagePresent
        self.allocatedBytes = allocatedBytes
        self.capacityBytes = capacityBytes
    }
}

public struct DistroInventoryItem: Sendable, Equatable {
    public let entry: DistroEntry
    public let isDefault: Bool
    public let storage: DistroStorageMetrics

    public init(entry: DistroEntry, isDefault: Bool, storage: DistroStorageMetrics) {
        precondition(Registry.isValidName(entry.name), "inventory entries must have valid names")
        precondition(entry.image == "\(entry.name).img", "inventory image names must be canonical")
        self.entry = entry
        self.isDefault = isDefault
        self.storage = storage
    }
}

public struct DistroInventorySnapshot: Sendable, Equatable {
    public let items: [DistroInventoryItem]
    public let defaultDistro: String?

    public init(items: [DistroInventoryItem], defaultDistro: String?) {
        precondition(
            Set(items.map { $0.entry.name }).count == items.count,
            "inventory names must be unique")
        precondition(
            defaultDistro == nil || items.contains { $0.entry.name == defaultDistro },
            "the default must name an inventory item")
        self.items = items
        self.defaultDistro = defaultDistro
    }
}

public enum DistroInventoryService {
    public static func snapshot(home: MSLHome) throws -> DistroInventorySnapshot {
        precondition(home.root.isFileURL, "MSL home must be a file URL")
        assert(!home.registryURL.path.isEmpty, "registry path must not be empty")
        let registry = try Registry.load(from: home.registryURL)
        let items = try registry.distros.map { entry in
            let storage = try storage(at: home.imageURL(name: entry.name))
            return DistroInventoryItem(
                entry: entry, isDefault: entry.name == registry.defaultDistro, storage: storage)
        }
        return DistroInventorySnapshot(items: items, defaultDistro: registry.defaultDistro)
    }

    private static func storage(at imageURL: URL) throws -> DistroStorageMetrics {
        precondition(imageURL.isFileURL, "image must be a file URL")
        assert(!imageURL.path.isEmpty, "image path must not be empty")
        var info = stat()
        guard stat(imageURL.path, &info) == 0 else {
            let code = errno
            if code == ENOENT {
                return DistroStorageMetrics(
                    imagePresent: false, allocatedBytes: 0, capacityBytes: 0)
            }
            throw MSLError.io("stat \(imageURL.path) failed: errno=\(code)")
        }
        guard info.st_blocks >= 0, info.st_size >= 0 else {
            throw MSLError.io("stat \(imageURL.path) returned negative storage metrics")
        }
        let allocated = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
        guard !allocated.overflow else {
            throw MSLError.io("allocated size overflow for \(imageURL.path)")
        }
        return DistroStorageMetrics(
            imagePresent: true, allocatedBytes: allocated.partialValue,
            capacityBytes: UInt64(info.st_size))
    }
}

public enum IECByteFormatter {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]

    public static func string(from bytes: UInt64) -> String {
        assert(!units.isEmpty, "the formatter must define a base unit")
        assert(units[0] == "B", "the first formatter unit must be bytes")
        guard bytes >= 1024 else { return "\(bytes) B" }
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(
            format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }
}
