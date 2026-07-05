import Darwin
import FSKit
import Foundation

/// File reads and the read-only mutation surface. `read` proxies the guest via
/// `readBytes`; every mutation entrypoint returns `EROFS` so read-only is
/// structural, not advisory.
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
        reply(0, fs_errorForPOSIXError(EROFS))
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        reply(nil, fs_errorForPOSIXError(EROFS))
    }

    func createItem(
        named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, nil, fs_errorForPOSIXError(EROFS))
    }

    func createSymbolicLink(
        named name: FSFileName, inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
        replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, nil, fs_errorForPOSIXError(EROFS))
    }

    func createLink(
        to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, fs_errorForPOSIXError(EROFS))
    }

    func removeItem(
        _ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(fs_errorForPOSIXError(EROFS))
    }

    // swiftlint:disable:next function_parameter_count
    func renameItem(
        _ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
        to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
        overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, fs_errorForPOSIXError(EROFS))
    }
}
