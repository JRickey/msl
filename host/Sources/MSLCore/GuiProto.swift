import Foundation

/// Surface protocol wire (docs/specs/m4-gui-protocol.md): a 16-byte binary
/// frame header (u32 type, u32 flags, u64 payload_len, little-endian) wrapping
/// JSON control payloads and one binary commit payload. Pure codec, no I/O.
///
/// Commit payload layout: a 56-byte fixed prefix (win, seq, w, h, stride,
/// format, scale_e12, n_rects, serial, reserved as u32; then
/// t_client_commit_ns, t_send_ns as u64), then n_rects × {x,y,w,h u32}, then
/// per-rect row-packed pixels (rect.w*4 bytes/row) in rect order. The serial
/// and reserved u32 keep the u64 timestamps 8-byte aligned at offsets 40/48.
public enum GuiProto {
    public static let port: UInt32 = 5020
    public static let version: UInt32 = 3
    public static let maxFrame = 64 * 1024 * 1024
    public static let headerSize = 16
    public static let maxRects = 4096
    public static let commitFixed = 56

    /// Encode the 16-byte frame header, rejecting an oversize payload up front.
    public static func header(type: UInt32, flags: UInt32, payloadLen: Int) throws -> Data {
        precondition(payloadLen >= 0, "payload length must be non-negative")
        guard payloadLen <= maxFrame else {
            throw MSLError.framing("gui frame \(payloadLen) exceeds \(maxFrame)")
        }
        var writer = GuiWriter()
        writer.u32(type)
        writer.u32(flags)
        writer.u64(UInt64(payloadLen))
        assert(writer.count == headerSize, "gui header must be 16 bytes")
        return writer.data
    }

    /// Parse the 16-byte header, enforcing the 64 MiB frame bound before the body
    /// is ever read (so an oversize length cannot drive an allocation).
    public static func parseHeader(_ data: Data) throws -> GuiHeader {
        guard data.count == headerSize else {
            throw MSLError.framing("gui header must be \(headerSize) bytes, got \(data.count)")
        }
        var reader = GuiReader(data)
        let type = try reader.u32()
        let flags = try reader.u32()
        let len = try reader.u64()
        guard len <= UInt64(maxFrame) else {
            throw MSLError.framing("gui frame \(len) exceeds \(maxFrame)")
        }
        assert(reader.remaining == 0, "header parse must consume all 16 bytes")
        return GuiHeader(type: type, flags: flags, len: Int(len))
    }

    /// Encode a control value to a JSON payload, enforcing the frame bound.
    public static func encode(_ value: some Encodable) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maxFrame else {
            throw MSLError.framing("gui payload \(data.count) exceeds \(maxFrame)")
        }
        assert(!data.isEmpty, "encoded control payload is never empty")
        return data
    }

    /// Decode a JSON control payload, rejecting an empty body before parsing.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty else { throw MSLError.protocolMismatch("empty gui payload") }
        guard data.count <= maxFrame else {
            throw MSLError.framing("gui payload \(data.count) exceeds \(maxFrame)")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Parsed frame header (type, flags, payload length).
public struct GuiHeader: Sendable, Equatable {
    public let type: UInt32
    public let flags: UInt32
    public let len: Int
}

/// A fully-read inbound frame handed from the reader thread to the presenter.
public struct GuiInboundFrame: Sendable {
    public let type: UInt32
    public let flags: UInt32
    public let payload: Data
}

/// Message type ids (odd = guest→host, even = host→guest) per the protocol.
public enum GuiType: UInt32, Sendable {
    case hello = 1
    case helloAck = 2
    case winNew = 3
    case configure = 4
    case winMap = 5
    case close = 6
    case winUnmap = 7
    case pointer = 8
    case winDestroy = 9
    case key = 10
    case winTitle = 11
    case presentAck = 12
    case commit = 13
    case statsReq = 14
    case cursorNamed = 15
    case stats = 17
    case winLimits = 19
}

/// Little-endian byte cursor over an immutable frame payload; every read is
/// bounds-checked and throws `MSLError.framing` on underflow.
struct GuiReader {
    private let bytes: [UInt8]
    private var cursor: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.cursor = 0
    }

    var remaining: Int { bytes.count - cursor }
    var offset: Int { cursor }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw MSLError.framing("gui read u32 underflow") }
        let base = cursor
        cursor += 4
        return UInt32(bytes[base]) | (UInt32(bytes[base + 1]) << 8)
            | (UInt32(bytes[base + 2]) << 16) | (UInt32(bytes[base + 3]) << 24)
    }

    mutating func u64() throws -> UInt64 {
        let low = try u32()
        let high = try u32()
        return UInt64(low) | (UInt64(high) << 32)
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0 else { throw MSLError.framing("gui read negative count") }
        guard remaining >= count else { throw MSLError.framing("gui read take underflow") }
        let base = cursor
        cursor += count
        return Data(bytes[base..<(base + count)])
    }
}

/// Little-endian append-only byte builder for control and header encoding.
struct GuiWriter {
    private var storage: [UInt8] = []

    var count: Int { storage.count }
    var data: Data { Data(storage) }

    mutating func u32(_ value: UInt32) {
        storage.append(UInt8(value & 0xff))
        storage.append(UInt8((value >> 8) & 0xff))
        storage.append(UInt8((value >> 16) & 0xff))
        storage.append(UInt8((value >> 24) & 0xff))
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(value & 0xffff_ffff))
        u32(UInt32((value >> 32) & 0xffff_ffff))
    }
}
