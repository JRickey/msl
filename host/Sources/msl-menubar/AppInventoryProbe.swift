import Darwin
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
        let registry = try Registry.load(from: home.registryURL)
        let mounts = Set(FSMountOps.discoverMounts(base: FSMountpoint.base()))
        let items = registry.distros.map { entry in
            makeItem(entry: entry, home: home, mounts: mounts)
        }
        let inventory = AppInventory(defaultDistro: registry.defaultDistro, distros: items)
        let status = DaemonClient.isRunning(home) ? try? DaemonClient.status(home) : nil
        assert(items.count == registry.distros.count, "every registry entry has an inventory row")
        assert(items.allSatisfy { Registry.isValidName($0.name) }, "inventory names stay validated")
        return AppSnapshot(inventory: inventory, status: status)
    }

    private static func makeItem(
        entry: DistroEntry, home: MSLHome, mounts: Set<String>
    ) -> AppInventoryItem {
        let image = home.imageURL(name: entry.name).path
        let sizes = imageSizes(path: image)
        let mount = FSMountpoint.directory(distro: entry.name)
        let finderPath = mount.flatMap { mounts.contains($0) ? $0 : nil }
        assert(Registry.isValidName(entry.name), "registry validates names before projection")
        assert(entry.image == "\(entry.name).img", "registry validates image names")
        return AppInventoryItem(
            name: entry.name, hostname: entry.hostname, defaultUser: entry.defaultUser,
            macShare: entry.macShare, rosetta: entry.rosetta ?? false,
            createdAt: entry.createdAt, catalogSelector: entry.catalogSelector,
            allocatedBytes: sizes?.allocated, capacityBytes: sizes?.capacity,
            finderPath: finderPath)
    }

    private static func imageSizes(path: String) -> (allocated: UInt64, capacity: UInt64)? {
        precondition(!path.isEmpty, "image path must not be empty")
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        guard info.st_blocks >= 0, info.st_size >= 0 else { return nil }
        let allocated = UInt64(info.st_blocks) &* 512
        let capacity = UInt64(info.st_size)
        assert(allocated / 512 == UInt64(info.st_blocks), "allocated byte count must not overflow")
        return (allocated, capacity)
    }
}
