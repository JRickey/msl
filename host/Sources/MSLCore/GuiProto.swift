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
    public static let version: UInt32 = 5
    public static let maxFrame = 64 * 1024 * 1024
    public static let headerSize = 16
    public static let maxRects = 4096
    public static let commitFixed = 56

    /// Clipboard MIME allowlist shared by both selection-offer decoders.
    public static let selMimeAllowlist: [String] = [
        "text/plain;charset=utf-8",
        "text/plain",
        "UTF8_STRING",
        "text/uri-list",
        "image/png",
    ]

    public static let selMaxEntries: UInt32 = 8
    public static let selMaxMimeLen: UInt32 = 128
    public static let selInlineMax: UInt64 = 65_536
    public static let selStreamMax: UInt64 = 33_554_432
    public static let selFlagInline: UInt32 = 1
    public static let selOfferPrefix = 24
    public static let selDescLen = 8

    public static let selChunkMax: UInt32 = 262_144
    public static let selFlagFinal: UInt32 = 1
    public static let selChunkPrefix = 16

    public static let cursorMinDim: UInt32 = 1
    public static let cursorMaxDim: UInt32 = 512
    public static let cursorPrefix = 24

    public static let winStrMax = 512
    public static let errReasonMax = 256
    public static let textFieldMax = 4096
    public static let helloOutputMax: UInt32 = 16_384
    public static let layoutNameMax = 64

    /// `cursor_rect` bounds the codec can enforce without window dimensions:
    /// coordinates in `[-coordMax, coordMax]`, dimensions in `[1, dimMax]`.
    public static let textRectCoordMax: Int32 = 16_384
    public static let textRectDimMax: UInt32 = 16_384

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

    /// Strip control characters and truncate to `cap` UTF-8 bytes on a scalar
    /// boundary. Untrusted guest strings are sanitized, not rejected.
    public static func sanitize(_ input: String, cap: Int) -> String {
        precondition(cap > 0, "sanitize cap must be positive")
        var out = ""
        var used = 0
        for scalar in input.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            let width = String(scalar).utf8.count
            if used + width > cap { break }
            out.unicodeScalars.append(scalar)
            used += width
        }
        assert(out.utf8.count <= cap, "sanitized text stays within the cap")
        return out
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
    case popupDismiss = 16
    case stats = 17
    case winLimits = 19
    case popupNew = 21
    case popupMoved = 23
    case selOffer = 25
    case hostSel = 26
    case textInputState = 27
    case textInputApply = 28
    case cursorImage = 29
    case setLayout = 30
    case errorGuestToHost = 31
    case errorHostToGuest = 32
    case selDataGuestToHost = 33
    case selReadHostToGuest = 34
    case selReadGuestToHost = 35
    case selDataHostToGuest = 36
}

/// Bounds-checked little-endian cursor over immutable `Data`; `take` returns a slice.
/// Indexing starts at `startIndex` because sliced `Data` need not be zero-based.
struct GuiReader {
    private let data: Data
    private let base: Int
    private var cursor: Int

    init(_ data: Data) {
        self.data = data
        self.base = data.startIndex
        self.cursor = 0
    }

    var remaining: Int { data.count - cursor }
    var offset: Int { cursor }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw MSLError.framing("gui read u32 underflow") }
        let index = base + cursor
        cursor += 4
        return UInt32(data[index]) | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16) | (UInt32(data[index + 3]) << 24)
    }

    mutating func u64() throws -> UInt64 {
        let low = try u32()
        let high = try u32()
        return UInt64(low) | (UInt64(high) << 32)
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0 else { throw MSLError.framing("gui read negative count") }
        guard remaining >= count else { throw MSLError.framing("gui read take underflow") }
        let start = base + cursor
        cursor += count
        return data[start..<(start + count)]
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

    mutating func bytes(_ blob: [UInt8]) {
        storage.append(contentsOf: blob)
    }

    mutating func bytes(_ blob: Data) {
        storage.append(contentsOf: blob)
    }
}

extension GuiProto {
    /// Parse a `commit`, validating every header bound (n_rects, stride, rect
    /// containment, exact pixel length) before trusting guest bytes.
    public static func parseCommit(_ data: Data) throws -> GuiCommit {
        guard data.count >= commitFixed else {
            throw MSLError.framing("commit shorter than \(commitFixed)-byte header")
        }
        var reader = GuiReader(data)
        let head = try readCommitHead(&reader)
        guard head.format <= 1 else {
            throw MSLError.protocolMismatch("commit format \(head.format) unsupported")
        }
        guard head.width > 0, head.height > 0 else {
            throw MSLError.protocolMismatch("commit has zero dimension")
        }
        guard UInt64(head.stride) >= UInt64(head.width) * 4 else {
            throw MSLError.protocolMismatch("commit stride \(head.stride) < w*4")
        }
        guard head.nRects <= UInt32(maxRects) else {
            throw MSLError.protocolMismatch("commit n_rects \(head.nRects) exceeds \(maxRects)")
        }
        let rects = try readRects(
            &reader, count: Int(head.nRects), bufW: head.width, bufH: head.height)
        let need = try pixelBytes(for: rects)
        guard UInt64(reader.remaining) >= need else {
            throw MSLError.framing("commit pixels short: have \(reader.remaining), need \(need)")
        }
        let pixels = try reader.take(Int(need))
        guard reader.remaining == 0 else {
            throw MSLError.framing(
                "commit has \(reader.remaining) trailing bytes (spec: no padding)")
        }
        return GuiCommit(
            win: head.win, seq: head.seq, width: head.width, height: head.height,
            stride: head.stride, format: head.format, scaleE12: head.scaleE12, serial: head.serial,
            rects: rects, tClientCommitNs: head.tClient, tSendNs: head.tSend, pixels: pixels)
    }

    private struct CommitHead {
        let win: UInt32
        let seq: UInt32
        let width: UInt32
        let height: UInt32
        let stride: UInt32
        let format: UInt32
        let scaleE12: UInt32
        let nRects: UInt32
        let serial: UInt32
        let tClient: UInt64
        let tSend: UInt64
    }

    private static func readCommitHead(_ reader: inout GuiReader) throws -> CommitHead {
        let win = try reader.u32()
        let seq = try reader.u32()
        let width = try reader.u32()
        let height = try reader.u32()
        let stride = try reader.u32()
        let format = try reader.u32()
        let scaleE12 = try reader.u32()
        let nRects = try reader.u32()
        let serial = try reader.u32()
        _ = try reader.u32()  // reserved: sender writes 0, receiver ignores the value
        let tClient = try reader.u64()
        let tSend = try reader.u64()
        assert(reader.offset == commitFixed, "commit head must consume the fixed prefix")
        return CommitHead(
            win: win, seq: seq, width: width, height: height, stride: stride, format: format,
            scaleE12: scaleE12, nRects: nRects, serial: serial, tClient: tClient, tSend: tSend)
    }

    private static func readRects(
        _ reader: inout GuiReader, count: Int, bufW: UInt32, bufH: UInt32
    ) throws -> [GuiRect] {
        precondition(count >= 0, "rect count must be non-negative")
        precondition(count <= maxRects, "rect count already bounded by caller")
        var rects: [GuiRect] = []
        rects.reserveCapacity(count)
        for _ in 0..<count {  // bounded: count ≤ maxRects (4096)
            let rect = GuiRect(
                originX: try reader.u32(), originY: try reader.u32(), width: try reader.u32(),
                height: try reader.u32())
            guard UInt64(rect.originX) + UInt64(rect.width) <= UInt64(bufW),
                UInt64(rect.originY) + UInt64(rect.height) <= UInt64(bufH)
            else {
                throw MSLError.protocolMismatch("commit rect outside buffer bounds")
            }
            rects.append(rect)
        }
        assert(rects.count == count, "rect parse must yield the requested count")
        return rects
    }

    private static func pixelBytes(for rects: [GuiRect]) throws -> UInt64 {
        precondition(rects.count <= maxRects, "rect count already bounded")
        var total: UInt64 = 0
        for rect in rects {  // bounded: rects.count ≤ maxRects
            total += UInt64(rect.width) * UInt64(rect.height) * 4
            guard total <= UInt64(maxFrame) else {
                throw MSLError.framing("commit pixel total exceeds \(maxFrame)")
            }
        }
        return total
    }
}
