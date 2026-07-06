import Darwin
import FSKit
import Foundation
import MSLFSWire

/// File reads and mutation callbacks. Read-only mounts reject mutations before
/// the guest sees them.
extension MSLVolume: FSVolume.ReadWriteOperations {
    func read(
        from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (Int, (any Error)?) -> Void
    ) {
        guard let msl = item as? MSLItem else {
            reply(0, fs_errorForPOSIXError(EINVAL))
            return
        }
        guard offset >= 0, length >= 0 else {
            reply(0, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let count = try readBytes(
                node: msl.nodeID, offset: UInt64(offset), length: length, buffer: buffer)
            reply(count, nil)
        } catch {
            reply(0, Self.mapError(error))
        }
    }

    func write(
        contents: Data, to item: FSItem, at offset: off_t,
        replyHandler reply: @escaping (Int, (any Error)?) -> Void
    ) {
        guard !readonly else {
            reply(0, fs_errorForPOSIXError(EROFS))
            return
        }
        guard let msl = item as? MSLItem, offset >= 0 else {
            reply(0, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let count = try writeBytes(node: msl.nodeID, offset: UInt64(offset), contents: contents)
            reply(count, nil)
        } catch {
            reply(0, Self.mapError(error))
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        newAttributes.consumedAttributes = []
        guard !readonly else {
            reply(nil, fs_errorForPOSIXError(EROFS))
            return
        }
        guard let msl = item as? MSLItem else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let mapped = try Self.setattrPayload(from: newAttributes)
            let attr = try applySetattr(mapped.setattr, to: msl)
            if mapped.setattr.mask != 0 { newAttributes.consumedAttributes = mapped.consumed }
            reply(MSLAttr.attributes(from: attr), nil)
        } catch {
            reply(nil, Self.mapError(error))
        }
    }

    func createItem(
        named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard !readonly else {
            reply(nil, nil, fs_errorForPOSIXError(EROFS))
            return
        }
        guard let dir = directory as? MSLItem, let component = validName(name) else {
            reply(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        guard let itemType = Self.protoItemType(type) else {
            reply(nil, nil, fs_errorForPOSIXError(EOPNOTSUPP))
            return
        }
        do {
            let inputs = Self.createInputs(type: itemType, attributes: newAttributes)
            let attr = try client.create(
                parent: dir.nodeID, name: component, itemType: itemType, mode: inputs.mode,
                uid: inputs.uid, gid: inputs.gid)
            let item = internItem(nodeID: attr.nodeID, itemType: attr.itemType, name: component)
            mutationChangedDirectory(dir.nodeID)
            reply(item, FSFileName(string: component), nil)
        } catch {
            reply(nil, nil, Self.mapError(error))
        }
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard !readonly else {
            reply(nil, nil, fs_errorForPOSIXError(EROFS))
            return
        }
        guard let dir = directory as? MSLItem, let component = validName(name),
            let target = contents.string, !target.isEmpty
        else {
            reply(nil, nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let ids = Self.ownerInputs(newAttributes)
            let attr = try client.symlink(
                parent: dir.nodeID, name: component, target: target, uid: ids.uid, gid: ids.gid)
            let item = internItem(nodeID: attr.nodeID, itemType: attr.itemType, name: component)
            mutationChangedDirectory(dir.nodeID)
            reply(item, FSFileName(string: component), nil)
        } catch {
            reply(nil, nil, Self.mapError(error))
        }
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        guard !readonly else {
            reply(nil, fs_errorForPOSIXError(EROFS))
            return
        }
        guard let msl = item as? MSLItem, let dir = directory as? MSLItem,
            let component = validName(name)
        else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let attr = try client.link(node: msl.nodeID, newParent: dir.nodeID, newName: component)
            _ = internItem(nodeID: attr.nodeID, itemType: attr.itemType, name: component)
            mutationChangedDirectory(dir.nodeID)
            reply(FSFileName(string: component), nil)
        } catch {
            reply(nil, Self.mapError(error))
        }
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard !readonly else {
            reply(fs_errorForPOSIXError(EROFS))
            return
        }
        guard let msl = item as? MSLItem, let dir = directory as? MSLItem,
            let component = validName(name)
        else {
            reply(fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            try client.remove(parent: dir.nodeID, name: component, itemType: msl.itemType)
            evictItem(nodeID: msl.nodeID)
            mutationChangedDirectory(dir.nodeID)
            reply(nil)
        } catch {
            reply(Self.mapError(error))
        }
    }

    // swiftlint:disable:next function_parameter_count
    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
        overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        guard !readonly else {
            reply(nil, fs_errorForPOSIXError(EROFS))
            return
        }
        guard let msl = item as? MSLItem, let src = sourceDirectory as? MSLItem,
            let dst = destinationDirectory as? MSLItem, let srcName = validName(sourceName),
            let dstName = validName(destinationName)
        else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        do {
            let attr = try client.rename(
                node: msl.nodeID, srcParent: src.nodeID, srcName: srcName, dstParent: dst.nodeID,
                dstName: dstName, replace: overItem != nil)
            if let replaced = overItem as? MSLItem { evictItem(nodeID: replaced.nodeID) }
            _ = internItem(nodeID: attr.nodeID, itemType: attr.itemType, name: dstName)
            mutationChangedDirectories(src.nodeID, dst.nodeID)
            reply(FSFileName(string: dstName), nil)
        } catch {
            reply(nil, Self.mapError(error))
        }
    }
}

extension MSLVolume {
    private func writeBytes(node: UInt64, offset: UInt64, contents: Data) throws -> Int {
        assert(node != 0, "file node id must be non-zero")
        guard !contents.isEmpty else { return 0 }
        var written = 0
        let maxPasses = contents.count / FSProto.writeRequestCap + 2
        for _ in 0..<maxPasses {
            if written >= contents.count { break }
            let end = min(written + FSProto.writeRequestCap, contents.count)
            let advanced = offset.addingReportingOverflow(UInt64(written))
            guard !advanced.overflow else {
                throw FSProto.PosixError(errno: EINVAL, message: "write offset overflow")
            }
            let chunk = Array(contents[written..<end])
            let result = try client.write(node: node, offset: advanced.partialValue, data: chunk)
            let count = Int(result.count)
            guard count <= chunk.count else {
                throw FSProto.PosixError(errno: EIO, message: "write count exceeds request")
            }
            written += count
            if count < chunk.count { break }
        }
        if written > 0 { invalidateStatfs() }
        return written
    }

    private func applySetattr(_ setattr: FSProto.SetAttr, to item: MSLItem) throws -> FSProto.Attr {
        assert(item.nodeID != 0, "item node id must be non-zero")
        assert(setattr.mask <= 0x7f, "setattr mask must only use supported bits")
        guard setattr.mask != 0 else {
            return try client.getattr(node: item.nodeID, wanted: Self.fullWanted)
        }
        let attr = try client.setattr(node: item.nodeID, setattr: setattr)
        invalidateStatfs()
        return attr
    }

    private func mutationChangedDirectory(_ nodeID: UInt64) {
        invalidateStatfs()
        bumpDirectory(nodeID: nodeID)
    }

    private func mutationChangedDirectories(_ first: UInt64, _ second: UInt64) {
        invalidateStatfs()
        bumpDirectories(first, second)
    }

    private func validName(_ name: FSFileName) -> String? {
        guard let component = name.string, Self.isValidComponent(component) else { return nil }
        return component
    }

    private static func setattrPayload(
        from request: FSItem.SetAttributesRequest
    ) throws -> (setattr: FSProto.SetAttr, consumed: FSItem.Attribute) {
        var builder = SetattrBuilder()
        try builder.apply(request)
        return (builder.value, builder.consumed)
    }

    private static func protoItemType(_ type: FSItem.ItemType) -> FSProto.ItemType? {
        switch type {
        case .file: return .file
        case .directory: return .directory
        default: return nil
        }
    }

    private static func createInputs(
        type: FSProto.ItemType, attributes: FSItem.SetAttributesRequest
    ) -> CreateInputs {
        let fallback: UInt32 = type == .directory ? 0o040_755 : 0o100_644
        let owner = ownerInputs(attributes)
        let mode = attributes.isValid(.mode) ? attributes.mode : fallback
        return CreateInputs(mode: mode, uid: owner.uid, gid: owner.gid)
    }

    private static func ownerInputs(_ attributes: FSItem.SetAttributesRequest) -> (
        uid: UInt32, gid: UInt32
    ) {
        let uid = attributes.isValid(.uid) ? attributes.uid : 0
        let gid = attributes.isValid(.gid) ? attributes.gid : 0
        return (uid, gid)
    }
}

private struct CreateInputs {
    let mode: UInt32
    let uid: UInt32
    let gid: UInt32
}

private struct SetattrBuilder {
    var mask: UInt32 = 0
    var mode: UInt32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
    var size: UInt64 = 0
    var atime = FSProto.Timespec(sec: 0, nsec: 0)
    var mtime = FSProto.Timespec(sec: 0, nsec: 0)
    var flags: UInt32 = 0
    var consumed: FSItem.Attribute = []

    var value: FSProto.SetAttr {
        FSProto.SetAttr(
            mask: mask, mode: mode, uid: uid, gid: gid, size: size, atime: atime, mtime: mtime,
            flags: flags)
    }

    mutating func apply(_ request: FSItem.SetAttributesRequest) throws {
        applyScalars(request)
        try applyTimes(request)
    }

    private mutating func applyScalars(_ request: FSItem.SetAttributesRequest) {
        if request.isValid(.mode) {
            mode = request.mode
            mark(.mode, FSProto.SetAttr.modeMask)
        }
        if request.isValid(.uid) {
            uid = request.uid
            mark(.uid, FSProto.SetAttr.uidMask)
        }
        if request.isValid(.gid) {
            gid = request.gid
            mark(.gid, FSProto.SetAttr.gidMask)
        }
        if request.isValid(.size) {
            size = request.size
            mark(.size, FSProto.SetAttr.sizeMask)
        }
    }

    private mutating func applyTimes(_ request: FSItem.SetAttributesRequest) throws {
        if request.isValid(.accessTime) {
            atime = try Self.protoTime(request.accessTime)
            mark(.accessTime, FSProto.SetAttr.atimeMask)
        }
        if request.isValid(.modifyTime) {
            mtime = try Self.protoTime(request.modifyTime)
            mark(.modifyTime, FSProto.SetAttr.mtimeMask)
        }
    }

    private mutating func mark(_ attr: FSItem.Attribute, _ bit: UInt32) {
        mask |= bit
        consumed.insert(attr)
    }

    private static func protoTime(_ value: timespec) throws -> FSProto.Timespec {
        guard value.tv_nsec >= 0, value.tv_nsec < 1_000_000_000 else {
            throw FSProto.PosixError(errno: EINVAL, message: "invalid timespec")
        }
        return FSProto.Timespec(sec: Int64(value.tv_sec), nsec: UInt32(value.tv_nsec))
    }
}
