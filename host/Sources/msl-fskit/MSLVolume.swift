import Darwin
import FSKit
import Foundation
import MSLFSWire

/// Read-only FSKit volume backed by the guest fs service. Every Finder operation
/// becomes an `FSClient` round trip; every mutation entrypoint returns `EROFS`
/// so read-only is structural, not advisory. A per-`nodeID` item cache gives
/// each guest node a stable `FSItem` identity across lookups.
final class MSLVolume: FSVolume, FSVolume.Operations {
    static let fullWanted: UInt32 = 0xFFFF_FFFF
    static let rootNodeID: UInt64 = 1
    static let stableVerifier = FSDirectoryVerifier(rawValue: 1)

    let client: FSClient
    private let distro: String
    private let cacheLock = NSLock()
    private var items: [UInt64: MSLItem] = [:]
    private var cachedStatfs: FSProto.Statfs?

    init(client: FSClient, distro: String) {
        assert(!distro.isEmpty, "volume distro must not be empty")
        self.client = client
        self.distro = distro
        super.init(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: distro))
    }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.caseFormat = .sensitive
        caps.supports64BitObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.doesNotSupportImmutableFiles = true
        caps.doesNotSupportSettingFilePermissions = true
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: FSProto.shortName)
        if let fresh = try? client.statfs() {
            cacheLock.lock()
            cachedStatfs = fresh
            cacheLock.unlock()
            apply(fresh, to: result)
        } else if let cached = snapshotStatfs() {
            apply(cached, to: result)
        }
        return result
    }
}

extension MSLVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64.max }
}

extension MSLVolume {
    func internItem(nodeID: UInt64, itemType: FSProto.ItemType, name: String) -> MSLItem {
        assert(nodeID != 0, "node id must be non-zero")
        assert(!name.isEmpty, "item name must not be empty")
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = items[nodeID] { return existing }
        let item = MSLItem(nodeID: nodeID, itemType: itemType, name: name)
        items[nodeID] = item
        return item
    }

    func evictItem(nodeID: UInt64) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        items.removeValue(forKey: nodeID)
    }

    func clearItems() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        items.removeAll()
    }

    func snapshotStatfs() -> FSProto.Statfs? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedStatfs
    }

    func apply(_ stat: FSProto.Statfs, to result: FSStatFSResult) {
        let block = stat.bsize == 0 ? 4096 : Int(stat.bsize)
        result.blockSize = block
        result.ioSize = block
        result.totalBlocks = stat.blocks
        result.availableBlocks = stat.bavail
        result.freeBlocks = stat.bfree
        result.totalFiles = stat.files
        result.freeFiles = stat.ffree
    }

    static func mapError(_ error: any Error) -> any Error {
        if let posix = error as? FSProto.PosixError {
            return fs_errorForPOSIXError(posix.errno == 0 ? EIO : posix.errno)
        }
        return fs_errorForPOSIXError(EIO)
    }

    static func isValidComponent(_ name: String) -> Bool {
        if name.isEmpty || name.utf8.count > 255 { return false }
        if name == "." || name == ".." { return false }
        return !name.utf8.contains(where: { $0 == 0 || $0 == UInt8(ascii: "/") })
    }
}

extension MSLVolume {
    func activate(
        options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void
    ) {
        do {
            let attr = try client.getattr(node: Self.rootNodeID, wanted: Self.fullWanted)
            let root = internItem(nodeID: Self.rootNodeID, itemType: attr.itemType, name: "/")
            MSLFSKitLog.volume.info("activate root distro ready")
            reply(root, nil)
        } catch {
            reply(nil, Self.mapError(error))
        }
    }

    func deactivate(
        options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        client.close()
        clearItems()
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        client.close()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try client.sync()
            reply(nil)
        } catch {
            reply(Self.mapError(error))
        }
    }

    func getAttributes(
        _ desired: FSItem.GetAttributesRequest, of item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let msl = item as? MSLItem else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let attr = try client.getattr(node: msl.nodeID, wanted: Self.fullWanted)
            reply(MSLAttr.attributes(from: attr), nil)
        } catch {
            reply(nil, Self.mapError(error))
        }
    }

    func lookupItem(
        named name: FSFileName, inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let dir = directory as? MSLItem else {
            reply(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        guard let component = name.string, Self.isValidComponent(component) else {
            reply(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let attr = try client.lookup(parent: dir.nodeID, name: component)
            let item = internItem(nodeID: attr.nodeID, itemType: attr.itemType, name: component)
            reply(item, FSFileName(string: component), nil)
        } catch {
            reply(nil, nil, Self.mapError(error))
        }
    }

    func readSymbolicLink(
        _ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        guard let msl = item as? MSLItem else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let target = try client.readlink(node: msl.nodeID)
            reply(FSFileName(string: target), nil)
        } catch {
            reply(nil, Self.mapError(error))
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let msl = item as? MSLItem {
            try? client.reclaim(node: msl.nodeID)
            evictItem(nodeID: msl.nodeID)
        }
        reply(nil)
    }

    // swiftlint:disable:next function_parameter_count
    func enumerateDirectory(
        _ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let dir = directory as? MSLItem else {
            reply(Self.stableVerifier, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            try enumerate(dir: dir, cookie: cookie, attributes: attributes, packer: packer)
            reply(Self.stableVerifier, nil)
        } catch {
            reply(Self.stableVerifier, Self.mapError(error))
        }
    }
}

extension MSLVolume {
    private func enumerate(
        dir: MSLItem, cookie: FSDirectoryCookie, attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) throws {
        assert(dir.nodeID != 0, "directory node id must be non-zero")
        // A stale/oversized cookie clamps to past-the-end (no entries), never traps.
        let start = Int(clamping: cookie.rawValue)
        let includeDots = attributes == nil
        var index = 0
        if includeDots {
            guard try packDots(dir: dir, start: start, packer: packer) else { return }
            index = 2
        }
        let entries = try client.readdirplus(node: dir.nodeID, wanted: Self.fullWanted)
        for entry in entries {  // bounded: guest returns a finite entry list
            if index >= start {
                let mapped = includeDots ? nil : MSLAttr.attributes(from: entry.attr)
                let packed = packer.packEntry(
                    name: FSFileName(string: entry.name),
                    itemType: MSLAttr.itemType(entry.attr.itemType),
                    itemID: MSLAttr.identifier(entry.attr.fileID),
                    nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)), attributes: mapped)
                if !packed { return }
            }
            index += 1
        }
    }

    private func packDots(
        dir: MSLItem, start: Int, packer: FSDirectoryEntryPacker
    ) throws -> Bool {
        guard start < 2 else { return true }
        let attr = try client.getattr(node: dir.nodeID, wanted: Self.fullWanted)
        let parentRaw =
            attr.parentID == 0 ? FSItem.Identifier.parentOfRoot.rawValue : attr.parentID
        let dots = [(name: ".", ino: attr.fileID), (name: "..", ino: parentRaw)]
        for position in 0..<dots.count where position >= start {  // bounded: two dot entries
            let dot = dots[position]
            let packed = packer.packEntry(
                name: FSFileName(string: dot.name), itemType: .directory,
                itemID: MSLAttr.identifier(dot.ino),
                nextCookie: FSDirectoryCookie(rawValue: UInt64(position + 1)), attributes: nil)
            if !packed { return false }
        }
        return true
    }

    /// Fill up to `min(length, buffer.length)` bytes by looping guest reads: each
    /// guest reply is capped at 1 MiB, so a larger FSKit request needs several,
    /// and a short/eof reply ends the fill (never truncates a >1 MiB read).
    func readBytes(
        node: UInt64, offset: UInt64, length: Int, buffer: FSMutableFileDataBuffer
    ) throws -> Int {
        assert(node != 0, "file node id must be non-zero")
        assert(length >= 0, "read length must be non-negative")
        let want = min(length, buffer.length)
        guard want > 0 else { return 0 }
        let handle = try client.open(node: node)
        defer { try? client.closeFile(handle: handle) }
        var filled = 0
        let maxPasses = want / FSProto.readReplyCap + 2  // bounded: one 1 MiB chunk per pass
        for _ in 0..<maxPasses {
            if filled >= want { break }
            let chunkLen = min(want - filled, FSProto.readReplyCap)
            let chunk = try client.read(
                handle: handle, offset: offset + UInt64(filled), length: UInt32(chunkLen))
            let take = min(chunk.data.count, chunkLen)
            if take > 0 {
                copyBytes(chunk.data, count: take, into: buffer, at: filled)
                filled += take
            }
            if chunk.eof { break }
            // Guest contract: a non-eof reply fills the request; anything short
            // is an anomaly, surfaced as EIO rather than a silent truncation.
            guard take == chunkLen else {
                throw FSProto.PosixError(errno: EIO, message: "short read without eof")
            }
        }
        return filled
    }

    private func copyBytes(
        _ data: [UInt8], count: Int, into buffer: FSMutableFileDataBuffer, at offset: Int
    ) {
        assert(count >= 0, "byte count must be non-negative")
        assert(count <= data.count, "count within source bounds")
        guard count > 0 else { return }
        buffer.withUnsafeMutableBytes { raw in
            guard raw.count >= offset + count else { return }
            let dest = UnsafeMutableRawBufferPointer(rebasing: raw[offset..<offset + count])
            dest.copyBytes(from: data[0..<count])
        }
    }
}
