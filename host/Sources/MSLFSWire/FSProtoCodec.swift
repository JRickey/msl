import Foundation

/// Little-endian byte writer for the FSKit file-service codec.
struct FSWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { appendLE(value) }
    mutating func u32(_ value: UInt32) { appendLE(value) }
    mutating func u64(_ value: UInt64) { appendLE(value) }
    mutating func i32(_ value: Int32) { appendLE(UInt32(bitPattern: value)) }
    mutating func i64(_ value: Int64) { appendLE(UInt64(bitPattern: value)) }

    mutating func string(_ value: String) throws {
        let utf8 = Array(value.utf8)
        guard utf8.count <= FSProto.stringMax else {
            throw FSProto.WireError.stringTooLong(utf8.count)
        }
        u16(UInt16(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func blob(_ value: [UInt8], max: Int? = nil) throws {
        guard value.count <= Int(UInt32.max) else {
            throw FSProto.WireError.oversizeBlob(value.count)
        }
        if let max {
            guard value.count <= max else { throw FSProto.WireError.oversizeBlob(value.count) }
        }
        u32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    private mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }
}

/// Little-endian byte reader with bounds checks and a trailing-byte check.
struct FSReader {
    private let bytes: [UInt8]
    private var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        precondition(count >= 0, "take count must be non-negative")
        let end = pos + count
        guard end <= bytes.count else { throw FSProto.WireError.truncated }
        let slice = bytes[pos..<end]
        pos = end
        return slice
    }

    mutating func u8() throws -> UInt8 {
        let slice = try take(1)
        guard let first = slice.first else { throw FSProto.WireError.truncated }
        return first
    }

    mutating func u16() throws -> UInt16 {
        let raw = Array(try take(2))
        return UInt16(raw[0]) | (UInt16(raw[1]) << 8)
    }

    mutating func u32() throws -> UInt32 {
        let raw = Array(try take(4))
        return UInt32(raw[0]) | (UInt32(raw[1]) << 8) | (UInt32(raw[2]) << 16)
            | (UInt32(raw[3]) << 24)
    }

    mutating func u64() throws -> UInt64 {
        let low = UInt64(try u32())
        let high = UInt64(try u32())
        return low | (high << 32)
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

    mutating func string() throws -> String {
        let count = Int(try u16())
        let raw = Array(try take(count))
        guard let value = String(bytes: raw, encoding: .utf8) else {
            throw FSProto.WireError.badUTF8
        }
        return value
    }

    mutating func blob(max: Int) throws -> [UInt8] {
        let count = Int(try u32())
        guard count <= max else { throw FSProto.WireError.oversizeBlob(count) }
        return Array(try take(count))
    }

    func finish() throws {
        guard pos == bytes.count else { throw FSProto.WireError.trailingBytes }
    }
}

extension FSProto.SetAttr {
    func write(into writer: inout FSWriter) {
        writer.u32(mask)
        writer.u32(mode)
        writer.u32(uid)
        writer.u32(gid)
        writer.u64(size)
        writer.i64(atime.sec)
        writer.u32(atime.nsec)
        writer.i64(mtime.sec)
        writer.u32(mtime.nsec)
        writer.u32(flags)
    }

    static func read(from reader: inout FSReader) throws -> FSProto.SetAttr {
        FSProto.SetAttr(
            mask: try reader.u32(), mode: try reader.u32(), uid: try reader.u32(),
            gid: try reader.u32(), size: try reader.u64(),
            atime: FSProto.Timespec(sec: try reader.i64(), nsec: try reader.u32()),
            mtime: FSProto.Timespec(sec: try reader.i64(), nsec: try reader.u32()),
            flags: try reader.u32())
    }
}

extension FSProto.ItemType {
    static func decode(_ value: UInt8) throws -> FSProto.ItemType {
        guard let item = FSProto.ItemType(rawValue: value) else {
            throw FSProto.WireError.badItemType(value)
        }
        return item
    }
}

extension FSProto.Attr {
    func write(into writer: inout FSWriter) {
        writer.u64(nodeID)
        writer.u64(fileID)
        writer.u64(parentID)
        writer.u8(itemType.rawValue)
        writer.u32(mode)
        writer.u32(uid)
        writer.u32(gid)
        writer.u32(nlink)
        writer.u64(size)
        writer.u64(allocSize)
        Self.writeTime(atime, into: &writer)
        Self.writeTime(mtime, into: &writer)
        Self.writeTime(ctime, into: &writer)
        writer.u32(flags)
    }

    private static func writeTime(_ time: FSProto.Timespec, into writer: inout FSWriter) {
        writer.i64(time.sec)
        writer.u32(time.nsec)
    }

    static func read(from reader: inout FSReader) throws -> FSProto.Attr {
        let node = try reader.u64()
        let file = try reader.u64()
        let parent = try reader.u64()
        let type = try FSProto.ItemType.decode(try reader.u8())
        let mode = try reader.u32()
        let uid = try reader.u32()
        let gid = try reader.u32()
        let nlink = try reader.u32()
        let size = try reader.u64()
        let alloc = try reader.u64()
        let atime = try readTime(from: &reader)
        let mtime = try readTime(from: &reader)
        let ctime = try readTime(from: &reader)
        let flags = try reader.u32()
        return FSProto.Attr(
            nodeID: node, fileID: file, parentID: parent, itemType: type, mode: mode, uid: uid,
            gid: gid, nlink: nlink, size: size, allocSize: alloc, atime: atime, mtime: mtime,
            ctime: ctime, flags: flags)
    }

    private static func readTime(from reader: inout FSReader) throws -> FSProto.Timespec {
        FSProto.Timespec(sec: try reader.i64(), nsec: try reader.u32())
    }
}
