import Darwin
import FSKit
import MSLFSWire

/// Maps the guest `FSProto.Attr`/`ItemType` onto FSKit's attribute model.
/// Assigning a property marks it valid; FSKit filters by `wantedAttributes`, so
/// every field the guest supplies is populated. Birth/backup/added times are
/// omitted because Linux `fstat` cannot supply them.
enum MSLAttr {
    static func itemType(_ type: FSProto.ItemType) -> FSItem.ItemType {
        switch type {
        case .unknown: return .unknown
        case .file: return .file
        case .directory: return .directory
        case .symlink: return .symlink
        case .fifo: return .fifo
        case .character: return .charDevice
        case .block: return .blockDevice
        case .socket: return .socket
        }
    }

    static func attributes(from attr: FSProto.Attr) -> FSItem.Attributes {
        assert(attr.atime.nsec < 1_000_000_000, "atime nsec must be a valid fraction")
        assert(attr.mtime.nsec < 1_000_000_000, "mtime nsec must be a valid fraction")
        let parentRaw = attr.parentID == 0 ? FSItem.Identifier.parentOfRoot.rawValue : attr.parentID
        let out = FSItem.Attributes()
        out.type = itemType(attr.itemType)
        out.mode = attr.mode
        out.uid = attr.uid
        out.gid = attr.gid
        out.linkCount = attr.nlink
        out.flags = attr.flags
        out.size = attr.size
        out.allocSize = attr.allocSize
        out.fileID = identifier(attr.fileID)
        out.parentID = identifier(parentRaw)
        out.accessTime = makeTimespec(attr.atime)
        out.modifyTime = makeTimespec(attr.mtime)
        out.changeTime = makeTimespec(attr.ctime)
        return out
    }

    static func identifier(_ raw: UInt64) -> FSItem.Identifier {
        FSItem.Identifier(rawValue: raw) ?? .invalid
    }

    private static func makeTimespec(_ time: FSProto.Timespec) -> timespec {
        assert(time.nsec < 1_000_000_000, "nsec must be a valid fraction")
        assert(time.sec > Int64.min, "sec must be a representable epoch value")
        return timespec(tv_sec: Int(time.sec), tv_nsec: Int(time.nsec))
    }
}
