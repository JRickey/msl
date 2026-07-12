import Foundation
import MSLCore
import MSLMenuBarCore

enum AppInventoryProbe {
    private static let queue = DispatchQueue(label: "dev.msl.app.inventory")

    static func snapshot(home: MSLHome) async throws -> AppSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try load(home: home))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func load(home: MSLHome) throws -> AppSnapshot {
        let source = try DistroInventoryService.snapshot(home: home)
        let mounts = Set(FSMountOps.discoverMounts(base: FSMountpoint.base()))
        let items = source.items.map { item in
            makeItem(item: item, mounts: mounts)
        }
        let inventory = AppInventory(defaultDistro: source.defaultDistro, distros: items)
        let status = try daemonStatus(home: home)
        assert(items.count == source.items.count, "every inventory item has an app row")
        assert(items.allSatisfy { Registry.isValidName($0.name) }, "inventory names stay validated")
        return AppSnapshot(inventory: inventory, status: status)
    }

    private static func makeItem(
        item: DistroInventoryItem, mounts: Set<String>
    ) -> AppInventoryItem {
        let entry = item.entry
        let mount = FSMountpoint.directory(distro: entry.name)
        let finderPath = mount.flatMap { mounts.contains($0) ? $0 : nil }
        assert(Registry.isValidName(entry.name), "registry validates names before projection")
        assert(entry.image == "\(entry.name).img", "registry validates image names")
        return AppInventoryItem(
            name: entry.name, hostname: entry.hostname, defaultUser: entry.defaultUser,
            macShare: entry.macShare, rosetta: entry.rosetta ?? false,
            createdAt: entry.createdAt, catalogSelector: entry.catalogSelector,
            allocatedBytes: item.storage.imagePresent ? item.storage.allocatedBytes : nil,
            capacityBytes: item.storage.imagePresent ? item.storage.capacityBytes : nil,
            finderPath: finderPath)
    }

    private static func daemonStatus(home: MSLHome) throws -> StatusData? {
        guard DaemonClient.isRunning(home) else { return nil }
        return try DaemonClient.status(home)
    }
}
