import Foundation

extension FSProto.Statfs {
    func write(into writer: inout FSWriter) {
        writer.u64(blocks)
        writer.u64(bfree)
        writer.u64(bavail)
        writer.u64(files)
        writer.u64(ffree)
        writer.u32(bsize)
        writer.u32(namemax)
    }

    static func read(from reader: inout FSReader) throws -> FSProto.Statfs {
        FSProto.Statfs(
            blocks: try reader.u64(), bfree: try reader.u64(), bavail: try reader.u64(),
            files: try reader.u64(), ffree: try reader.u64(), bsize: try reader.u32(),
            namemax: try reader.u32())
    }
}

extension FSProto {
    /// A request with its id, ready to frame.
    public struct RequestFrame: Sendable, Equatable {
        public let id: UInt64
        public let request: Request
        public init(id: UInt64, request: Request) {
            self.id = id
            self.request = request
        }

        public func encode() throws -> [UInt8] {
            var writer = FSWriter()
            writer.u8(request.op)
            writer.u64(id)
            try writeArgs(into: &writer)
            return writer.bytes
        }

        private func writeArgs(into writer: inout FSWriter) throws {
            switch request {
            case .statfs, .sync, .close: break
            case .lookup(let parent, let name):
                writer.u64(parent)
                try writer.string(name)
            case .getattr(let node, let wanted):
                writer.u64(node)
                writer.u32(wanted)
            case .readdirplus(let node, let cookie, let maxEntries, let wanted):
                writer.u64(node)
                writer.u64(cookie)
                writer.u32(maxEntries)
                writer.u32(wanted)
            case .open(let node, let mode):
                writer.u64(node)
                writer.u8(mode)
            case .read(let handle, let offset, let length):
                writer.u64(handle)
                writer.u64(offset)
                writer.u32(length)
            case .closeFile(let handle): writer.u64(handle)
            case .readlink(let node), .reclaim(let node): writer.u64(node)
            default: try writeMutationArgs(into: &writer)
            }
        }

        private func writeMutationArgs(into writer: inout FSWriter) throws {
            switch request {
            case .write(let node, let offset, let data):
                writer.u64(node)
                writer.u64(offset)
                try writer.blob(data, max: FSProto.writeRequestMax)
            case .setattr(let node, let setattr):
                writer.u64(node)
                setattr.write(into: &writer)
            case .create(let parent, let name, let itemType, let mode, let uid, let gid):
                writer.u64(parent)
                try writer.string(name)
                writer.u8(itemType.rawValue)
                writer.u32(mode)
                writer.u32(uid)
                writer.u32(gid)
            case .symlink(let parent, let name, let target, let uid, let gid):
                writer.u64(parent)
                try writer.string(name)
                try writer.string(target)
                writer.u32(uid)
                writer.u32(gid)
            case .link(let node, let newParent, let newName):
                writer.u64(node)
                writer.u64(newParent)
                try writer.string(newName)
            case .remove(let parent, let name, let itemType):
                writer.u64(parent)
                try writer.string(name)
                writer.u8(itemType.rawValue)
            case .rename(
                let node, let srcParent, let srcName, let dstParent, let dstName, let flags):
                writer.u64(node)
                writer.u64(srcParent)
                try writer.string(srcName)
                writer.u64(dstParent)
                try writer.string(dstName)
                writer.u8(flags)
            default: break
            }
        }

        public static func decode(_ bytes: [UInt8]) throws -> RequestFrame {
            var reader = FSReader(bytes)
            let op = try reader.u8()
            let id = try reader.u64()
            let request = try readRequest(op: op, from: &reader)
            try reader.finish()
            return RequestFrame(id: id, request: request)
        }

        private static func readRequest(op: UInt8, from reader: inout FSReader) throws -> Request {
            switch op {
            case 1: return .statfs
            case 2: return .lookup(parent: try reader.u64(), name: try reader.string())
            case 3: return .getattr(node: try reader.u64(), wanted: try reader.u32())
            case 4:
                return .readdirplus(
                    node: try reader.u64(), cookie: try reader.u64(),
                    maxEntries: try reader.u32(), wanted: try reader.u32())
            case 5: return .open(node: try reader.u64(), mode: try reader.u8())
            case 6:
                return .read(
                    handle: try reader.u64(), offset: try reader.u64(), length: try reader.u32())
            default: return try readNodeRequest(op: op, from: &reader)
            }
        }

        private static func readNodeRequest(
            op: UInt8, from reader: inout FSReader
        ) throws -> Request {
            switch op {
            case 7: return .closeFile(handle: try reader.u64())
            case 8: return .readlink(node: try reader.u64())
            case 9: return .reclaim(node: try reader.u64())
            case 10: return .sync
            case 11: return .close
            default: return try readMutationRequest(op: op, from: &reader)
            }
        }

        private static func readMutationRequest(
            op: UInt8, from reader: inout FSReader
        ) throws -> Request {
            switch op {
            case 12:
                return .write(
                    node: try reader.u64(), offset: try reader.u64(),
                    data: try reader.blob(max: FSProto.writeRequestMax))
            case 13:
                return .setattr(
                    node: try reader.u64(), setattr: try SetAttr.read(from: &reader))
            case 14:
                return .create(
                    parent: try reader.u64(), name: try reader.string(),
                    itemType: try ItemType.decode(try reader.u8()), mode: try reader.u32(),
                    uid: try reader.u32(), gid: try reader.u32())
            case 15:
                return .symlink(
                    parent: try reader.u64(), name: try reader.string(),
                    target: try reader.string(), uid: try reader.u32(), gid: try reader.u32())
            case 16:
                return .link(
                    node: try reader.u64(), newParent: try reader.u64(),
                    newName: try reader.string())
            case 17:
                return .remove(
                    parent: try reader.u64(), name: try reader.string(),
                    itemType: try ItemType.decode(try reader.u8()))
            case 18:
                return .rename(
                    node: try reader.u64(), srcParent: try reader.u64(),
                    srcName: try reader.string(), dstParent: try reader.u64(),
                    dstName: try reader.string(), flags: try reader.u8())
            default: throw WireError.badOp(op)
            }
        }
    }

    /// A reply with its echoed id and op, carrying either a body or an error.
    public struct ReplyFrame: Sendable, Equatable {
        public let id: UInt64
        public let op: UInt8
        public let result: Result<ReplyBody, PosixError>

        public init(id: UInt64, op: UInt8, result: Result<ReplyBody, PosixError>) {
            self.id = id
            self.op = op
            self.result = result
        }

        public static func ok(id: UInt64, op: UInt8, body: ReplyBody) -> ReplyFrame {
            ReplyFrame(id: id, op: op, result: .success(body))
        }

        public static func error(
            id: UInt64, op: UInt8, errno: Int32, message: String
        ) -> ReplyFrame {
            ReplyFrame(id: id, op: op, result: .failure(PosixError(errno: errno, message: message)))
        }

        public func encode() throws -> [UInt8] {
            var writer = FSWriter()
            writer.u64(id)
            writer.u8(op)
            switch result {
            case .success(let body):
                writer.i32(0)
                try Self.writeBody(body, into: &writer)
            case .failure(let error):
                writer.i32(error.errno)
                try writer.string(error.message)
            }
            return writer.bytes
        }

        private static func writeBody(_ body: ReplyBody, into writer: inout FSWriter) throws {
            switch body {
            case .statfs(let statfs): statfs.write(into: &writer)
            case .attr(let attr): attr.write(into: &writer)
            case .readdirplus(let eof, let nextCookie, let entries):
                try writeReaddirplus(
                    eof: eof, nextCookie: nextCookie, entries: entries, into: &writer)
            case .open(let handle): writer.u64(handle)
            case .read(let data, let eof):
                try writer.blob(data)
                writer.u8(eof ? 1 : 0)
            case .readlink(let target): try writer.string(target)
            case .write(let count, let attr):
                writer.u32(count)
                attr.write(into: &writer)
            case .empty: break
            }
        }

        private static func writeReaddirplus(
            eof: Bool, nextCookie: UInt64, entries: [DirEntry], into writer: inout FSWriter
        ) throws {
            writer.u8(eof ? 1 : 0)
            writer.u64(nextCookie)
            writer.u32(UInt32(entries.count))
            for entry in entries {  // bounded: entries count fits u32
                try writer.string(entry.name)
                entry.attr.write(into: &writer)
            }
        }

        public static func decode(_ bytes: [UInt8]) throws -> ReplyFrame {
            var reader = FSReader(bytes)
            let id = try reader.u64()
            let op = try reader.u8()
            let errno = try reader.i32()
            let result: Result<ReplyBody, PosixError>
            if errno == 0 {
                result = .success(try readBody(op: op, from: &reader))
            } else {
                result = .failure(PosixError(errno: errno, message: try reader.string()))
            }
            try reader.finish()
            return ReplyFrame(id: id, op: op, result: result)
        }

        private static func readBody(op: UInt8, from reader: inout FSReader) throws -> ReplyBody {
            switch op {
            case 1: return .statfs(try Statfs.read(from: &reader))
            case 2, 3: return .attr(try Attr.read(from: &reader))
            case 4: return try readReaddirplus(from: &reader)
            case 5: return .open(handle: try reader.u64())
            case 6:
                return .read(
                    data: try reader.blob(max: FSProto.readReplyMax), eof: try reader.u8() != 0)
            case 8: return .readlink(target: try reader.string())
            case 12:
                return .write(count: try reader.u32(), attr: try Attr.read(from: &reader))
            case 13, 14, 15, 16, 18: return .attr(try Attr.read(from: &reader))
            case 7, 9, 10, 11, 17: return .empty
            default: throw WireError.badOp(op)
            }
        }

        private static func readReaddirplus(from reader: inout FSReader) throws -> ReplyBody {
            let eof = try reader.u8() != 0
            let nextCookie = try reader.u64()
            let count = Int(try reader.u32())
            var entries: [DirEntry] = []
            entries.reserveCapacity(min(count, 4096))
            for _ in 0..<count {  // bounded: count from the wire, entries bounded by frame cap
                let name = try reader.string()
                let attr = try Attr.read(from: &reader)
                entries.append(DirEntry(name: name, attr: attr))
            }
            return .readdirplus(eof: eof, nextCookie: nextCookie, entries: entries)
        }
    }
}
