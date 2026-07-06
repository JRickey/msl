import Foundation

/// FSKit file-service protocol v2: the compact binary request/reply codec,
/// byte-identical to the guest `msl-wire::fs` implementation (kept in lockstep
/// by a shared golden vector in the tests). All integers are little-endian;
/// strings are u16-length-prefixed UTF-8; data blobs are u32-length-prefixed. See
/// docs/specs/fskit-file-protocol.md. These types nest under `FSProto`, which
/// also carries the transport constants (FSProto.swift).
extension FSProto {
    /// Single `read` reply data cap (frame cap is `FSProto.frameMax`).
    public static let readReplyMax = 1 << 20
    /// Single `write` request data cap.
    public static let writeRequestMax = 1 << 20
    /// Maximum encodable string byte length (u16 prefix).
    public static let stringMax = Int(UInt16.max)

    /// Linux item type mapped to `FSItem.ItemType` on the host.
    public enum ItemType: UInt8, Sendable, Equatable {
        case unknown = 0
        case file = 1
        case directory = 2
        case symlink = 3
        case fifo = 4
        case character = 5
        case block = 6
        case socket = 7
    }

    /// A timestamp with nanosecond precision.
    public struct Timespec: Sendable, Equatable {
        public let sec: Int64
        public let nsec: UInt32
        public init(sec: Int64, nsec: UInt32) {
            self.sec = sec
            self.nsec = nsec
        }
    }

    /// File attributes returned by lookup / getattr / readdirplus.
    public struct Attr: Sendable, Equatable {
        public var nodeID: UInt64
        public var fileID: UInt64
        public var parentID: UInt64
        public var itemType: ItemType
        public var mode: UInt32
        public var uid: UInt32
        public var gid: UInt32
        public var nlink: UInt32
        public var size: UInt64
        public var allocSize: UInt64
        public var atime: Timespec
        public var mtime: Timespec
        public var ctime: Timespec
        public var flags: UInt32

        public init(
            nodeID: UInt64, fileID: UInt64, parentID: UInt64, itemType: ItemType, mode: UInt32,
            uid: UInt32, gid: UInt32, nlink: UInt32, size: UInt64, allocSize: UInt64,
            atime: Timespec, mtime: Timespec, ctime: Timespec, flags: UInt32
        ) {
            self.nodeID = nodeID
            self.fileID = fileID
            self.parentID = parentID
            self.itemType = itemType
            self.mode = mode
            self.uid = uid
            self.gid = gid
            self.nlink = nlink
            self.size = size
            self.allocSize = allocSize
            self.atime = atime
            self.mtime = mtime
            self.ctime = ctime
            self.flags = flags
        }
    }

    /// Filesystem statistics.
    public struct Statfs: Sendable, Equatable {
        public let blocks: UInt64
        public let bfree: UInt64
        public let bavail: UInt64
        public let files: UInt64
        public let ffree: UInt64
        public let bsize: UInt32
        public let namemax: UInt32
        public init(
            blocks: UInt64, bfree: UInt64, bavail: UInt64, files: UInt64, ffree: UInt64,
            bsize: UInt32, namemax: UInt32
        ) {
            self.blocks = blocks
            self.bfree = bfree
            self.bavail = bavail
            self.files = files
            self.ffree = ffree
            self.bsize = bsize
            self.namemax = namemax
        }
    }

    /// Attribute update mask and values for setattr/truncate requests.
    public struct SetAttr: Sendable, Equatable {
        public static let modeMask: UInt32 = 0x0001
        public static let uidMask: UInt32 = 0x0002
        public static let gidMask: UInt32 = 0x0004
        public static let sizeMask: UInt32 = 0x0008
        public static let atimeMask: UInt32 = 0x0010
        public static let mtimeMask: UInt32 = 0x0020
        public static let flagsMask: UInt32 = 0x0040

        public let mask: UInt32
        public let mode: UInt32
        public let uid: UInt32
        public let gid: UInt32
        public let size: UInt64
        public let atime: Timespec
        public let mtime: Timespec
        public let flags: UInt32

        public init(
            mask: UInt32, mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0,
            size: UInt64 = 0, atime: Timespec = Timespec(sec: 0, nsec: 0),
            mtime: Timespec = Timespec(sec: 0, nsec: 0), flags: UInt32 = 0
        ) {
            self.mask = mask
            self.mode = mode
            self.uid = uid
            self.gid = gid
            self.size = size
            self.atime = atime
            self.mtime = mtime
            self.flags = flags
        }
    }

    /// One readdirplus entry: name plus full attributes.
    public struct DirEntry: Sendable, Equatable {
        public let name: String
        public let attr: Attr
        public init(name: String, attr: Attr) {
            self.name = name
            self.attr = attr
        }
    }

    /// A file-service request.
    public enum Request: Sendable, Equatable {
        case statfs
        case lookup(parent: UInt64, name: String)
        case getattr(node: UInt64, wanted: UInt32)
        case readdirplus(node: UInt64, cookie: UInt64, maxEntries: UInt32, wanted: UInt32)
        case open(node: UInt64, mode: UInt8)
        case read(handle: UInt64, offset: UInt64, length: UInt32)
        case closeFile(handle: UInt64)
        case readlink(node: UInt64)
        case reclaim(node: UInt64)
        case sync
        case close
        case write(node: UInt64, offset: UInt64, data: [UInt8])
        case setattr(node: UInt64, setattr: SetAttr)
        case create(
            parent: UInt64, name: String, itemType: ItemType, mode: UInt32, uid: UInt32, gid: UInt32
        )
        case symlink(parent: UInt64, name: String, target: String, uid: UInt32, gid: UInt32)
        case link(node: UInt64, newParent: UInt64, newName: String)
        case remove(parent: UInt64, name: String, itemType: ItemType)
        case rename(
            node: UInt64, srcParent: UInt64, srcName: String, dstParent: UInt64, dstName: String,
            flags: UInt8
        )

        public var op: UInt8 {
            switch self {
            case .statfs: return 1
            case .lookup: return 2
            case .getattr: return 3
            case .readdirplus: return 4
            case .open: return 5
            case .read: return 6
            case .closeFile: return 7
            case .readlink: return 8
            case .reclaim: return 9
            case .sync: return 10
            case .close: return 11
            case .write: return 12
            case .setattr: return 13
            case .create: return 14
            case .symlink: return 15
            case .link: return 16
            case .remove: return 17
            case .rename: return 18
            }
        }
    }

    /// A successful reply body, tagged by the request op it answers.
    public enum ReplyBody: Sendable, Equatable {
        case statfs(Statfs)
        case attr(Attr)
        case readdirplus(eof: Bool, nextCookie: UInt64, entries: [DirEntry])
        case open(handle: UInt64)
        case read(data: [UInt8], eof: Bool)
        case readlink(target: String)
        case write(count: UInt32, attr: Attr)
        case empty
    }

    /// A POSIX error reply.
    public struct PosixError: Error, Sendable, Equatable {
        public let errno: Int32
        public let message: String
        public init(errno: Int32, message: String) {
            self.errno = errno
            self.message = message
        }
    }

    /// Codec failures on encode or decode.
    public enum WireError: Error, Sendable, Equatable {
        case truncated
        case badOp(UInt8)
        case badItemType(UInt8)
        case badUTF8
        case trailingBytes
        case oversizeBlob(Int)
        case stringTooLong(Int)
    }
}
