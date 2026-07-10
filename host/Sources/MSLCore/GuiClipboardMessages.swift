import Foundation

/// One entry in a selection offer: a MIME name, its byte length, and (inline
/// only) its payload bytes.
public struct GuiSelEntry: Sendable, Equatable {
    public let mime: String
    public let dataLen: UInt32
    public let data: Data

    public init(mime: String, dataLen: UInt32, data: Data) {
        self.mime = mime
        self.dataLen = dataLen
        self.data = data
    }
}

/// A clipboard selection offer (`sel_offer`/`host_sel`). An empty entry list
/// with `totalLen == 0` is a cleared selection.
public struct GuiSelOffer: Sendable, Equatable {
    public let serial: UInt32
    public let origin: UInt32
    public let flags: UInt32
    public let totalLen: UInt64
    public let entries: [GuiSelEntry]

    public var inline: Bool { flags & GuiProto.selFlagInline != 0 }

    public init(
        serial: UInt32, origin: UInt32, flags: UInt32, totalLen: UInt64, entries: [GuiSelEntry]
    ) {
        self.serial = serial
        self.origin = origin
        self.flags = flags
        self.totalLen = totalLen
        self.entries = entries
    }
}

/// A streamed selection payload chunk (`sel_data`); `flags` bit 0 marks the
/// final chunk of a read.
public struct GuiSelChunk: Sendable, Equatable {
    public let serial: UInt32
    public let mimeIdx: UInt32
    public let flags: UInt32
    public let data: Data

    public var isFinal: Bool { flags & GuiProto.selFlagFinal != 0 }

    public init(serial: UInt32, mimeIdx: UInt32, flags: UInt32, data: Data) {
        self.serial = serial
        self.mimeIdx = mimeIdx
        self.flags = flags
        self.data = data
    }
}

/// A demand `sel_read {serial, mime, cancel}` for a streamed selection.
public struct GuiSelRead: Codable, Sendable, Equatable {
    public let serial: UInt32
    public let mime: String
    public let cancel: Bool

    public init(serial: UInt32, mime: String, cancel: Bool) {
        self.serial = serial
        self.mime = mime
        self.cancel = cancel
    }
}

extension GuiProto {
    /// Encode a selection offer, validating the entry count, per-MIME cap, and
    /// `totalLen == sum(dataLen)` so a round-trip cannot produce a frame the
    /// decoder rejects.
    public static func encodeSelOffer(_ offer: GuiSelOffer) throws -> Data {
        guard offer.entries.count <= Int(selMaxEntries) else {
            throw MSLError.protocolMismatch("selection entries exceed 8")
        }
        let inline = offer.inline
        var sum: UInt64 = 0
        for entry in offer.entries {
            guard entry.mime.utf8.count <= Int(selMaxMimeLen) else {
                throw MSLError.protocolMismatch("mime length exceeds 128")
            }
            if inline, UInt64(entry.data.count) != UInt64(entry.dataLen) {
                throw MSLError.protocolMismatch("inline payload length mismatch")
            }
            sum &+= UInt64(entry.dataLen)
        }
        guard sum == offer.totalLen else {
            throw MSLError.protocolMismatch("total_len != sum(data_len)")
        }
        try checkOfferCeiling(inline: inline, totalLen: offer.totalLen)
        assert(offer.entries.count <= Int(selMaxEntries), "entry count bounded")
        assert(sum == offer.totalLen, "declared total matches descriptor sum")
        var writer = GuiWriter()
        writer.u32(offer.serial)
        writer.u32(offer.origin)
        writer.u32(UInt32(offer.entries.count))
        writer.u32(offer.flags)
        writer.u64(offer.totalLen)
        for entry in offer.entries {
            writer.u32(UInt32(entry.mime.utf8.count))
            writer.u32(entry.dataLen)
        }
        for entry in offer.entries { writer.bytes(Array(entry.mime.utf8)) }
        if inline { for entry in offer.entries { writer.bytes(entry.data) } }
        return writer.data
    }

    /// Reject an offer whose declared total exceeds the tier's ceiling, so no
    /// encoder emits a frame the peer decoder is guaranteed to reject.
    private static func checkOfferCeiling(inline: Bool, totalLen: UInt64) throws {
        if inline {
            guard totalLen <= selInlineMax else {
                throw MSLError.protocolMismatch("inline selection exceeds 64 KiB")
            }
        } else {
            guard totalLen <= selStreamMax else {
                throw MSLError.protocolMismatch("streamed selection exceeds 32 MiB")
            }
        }
        assert(totalLen <= selStreamMax, "total within the larger ceiling")
    }

    private struct SelPrefix {
        let serial: UInt32
        let origin: UInt32
        let entryCount: Int
        let flags: UInt32
        let totalLen: UInt64
        var inline: Bool { flags & GuiProto.selFlagInline != 0 }
    }

    /// Decode a selection offer, enforcing every invariant before it trusts a
    /// length: entry count, MIME cap/UTF-8/allowlist/uniqueness, size sums, and
    /// exact framing with no trailing bytes.
    public static func decodeSelOffer(_ data: Data) throws -> GuiSelOffer {
        guard data.count >= selOfferPrefix else {
            throw MSLError.framing("selection offer shorter than 24-byte prefix")
        }
        var reader = GuiReader(data)
        let prefix = try readSelPrefix(&reader)
        var mimeLens: [UInt32] = []
        var dataLens: [UInt32] = []
        try readSelDescriptors(&reader, prefix, &mimeLens, &dataLens)
        try checkSelSizes(prefix, mimeLens: mimeLens, frameLen: data.count)
        let mimes = try readSelMimes(&reader, prefix, mimeLens)
        let entries = try readSelPayloads(&reader, prefix, mimes, dataLens)
        assert(entries.count == prefix.entryCount, "entry count matches header")
        assert(reader.remaining == 0, "selection offer fully consumed")
        return GuiSelOffer(
            serial: prefix.serial, origin: prefix.origin, flags: prefix.flags,
            totalLen: prefix.totalLen, entries: entries)
    }

    /// Enforce the empty-selection rule, the inline/streamed ceilings, and exact
    /// framing using descriptor lengths only, before any MIME string is built.
    private static func checkSelSizes(
        _ prefix: SelPrefix, mimeLens: [UInt32], frameLen: Int
    ) throws {
        assert(prefix.entryCount <= Int(selMaxEntries), "entry count bounded")
        if prefix.entryCount == 0, prefix.totalLen != 0 {
            throw MSLError.protocolMismatch("empty selection must carry zero total_len")
        }
        var mimeBytes = 0
        for len in mimeLens { mimeBytes += Int(len) }
        let mimeEnd = selOfferPrefix + prefix.entryCount * selDescLen + mimeBytes
        if prefix.inline {
            guard prefix.totalLen <= selInlineMax else {
                throw MSLError.protocolMismatch("inline selection exceeds 64 KiB")
            }
            guard frameLen == mimeEnd + Int(prefix.totalLen) else {
                throw MSLError.protocolMismatch("inline selection frame size mismatch")
            }
        } else {
            guard prefix.totalLen <= selStreamMax else {
                throw MSLError.protocolMismatch("streamed selection exceeds 32 MiB")
            }
            guard frameLen == mimeEnd else {
                throw MSLError.protocolMismatch("streamed selection carries payload bytes")
            }
        }
        assert(mimeEnd <= frameLen, "mime region within frame")
    }

    private static func readSelPrefix(_ reader: inout GuiReader) throws -> SelPrefix {
        let serial = try reader.u32()
        let origin = try reader.u32()
        let count = try reader.u32()
        let flags = try reader.u32()
        let totalLen = try reader.u64()
        guard count <= selMaxEntries else {
            throw MSLError.protocolMismatch("selection entries exceed 8")
        }
        assert(count <= selMaxEntries, "entry count bounded")
        return SelPrefix(
            serial: serial, origin: origin, entryCount: Int(count), flags: flags,
            totalLen: totalLen)
    }

    private static func readSelDescriptors(
        _ reader: inout GuiReader, _ prefix: SelPrefix, _ mimeLens: inout [UInt32],
        _ dataLens: inout [UInt32]
    ) throws {
        var sum: UInt64 = 0
        for _ in 0..<prefix.entryCount {
            let mimeLen = try reader.u32()
            let dataLen = try reader.u32()
            guard mimeLen <= selMaxMimeLen else {
                throw MSLError.protocolMismatch("mime length exceeds 128")
            }
            mimeLens.append(mimeLen)
            dataLens.append(dataLen)
            sum &+= UInt64(dataLen)
        }
        guard sum == prefix.totalLen else {
            throw MSLError.protocolMismatch("total_len != sum(data_len)")
        }
        assert(mimeLens.count == prefix.entryCount, "one descriptor per entry")
    }

    private static func readSelMimes(
        _ reader: inout GuiReader, _ prefix: SelPrefix, _ mimeLens: [UInt32]
    ) throws -> [String] {
        var mimes: [String] = []
        for index in 0..<prefix.entryCount {
            let raw = try reader.take(Int(mimeLens[index]))
            guard let mime = String(data: raw, encoding: .utf8) else {
                throw MSLError.protocolMismatch("mime is not valid utf-8")
            }
            guard selMimeAllowlist.contains(mime) else {
                throw MSLError.protocolMismatch("mime outside allowlist")
            }
            guard !mimes.contains(mime) else {
                throw MSLError.protocolMismatch("duplicate mime in selection offer")
            }
            mimes.append(mime)
        }
        assert(mimes.count == prefix.entryCount, "one mime per entry")
        return mimes
    }

    private static func readSelPayloads(
        _ reader: inout GuiReader, _ prefix: SelPrefix, _ mimes: [String], _ dataLens: [UInt32]
    ) throws -> [GuiSelEntry] {
        assert(dataLens.count == prefix.entryCount, "one data length per entry")
        var entries: [GuiSelEntry] = []
        if prefix.inline {
            for index in 0..<prefix.entryCount {
                let payload = try reader.take(Int(dataLens[index]))
                entries.append(
                    GuiSelEntry(mime: mimes[index], dataLen: dataLens[index], data: payload))
            }
        } else {
            for index in 0..<prefix.entryCount {
                entries.append(
                    GuiSelEntry(mime: mimes[index], dataLen: dataLens[index], data: Data()))
            }
        }
        assert(entries.count == prefix.entryCount, "one entry per descriptor")
        return entries
    }

    public static func encodeSelChunk(_ chunk: GuiSelChunk) throws -> Data {
        guard chunk.data.count <= Int(selChunkMax) else {
            throw MSLError.protocolMismatch("chunk exceeds 256 KiB")
        }
        assert(chunk.data.count <= Int(selChunkMax), "chunk length bounded")
        var writer = GuiWriter()
        writer.u32(chunk.serial)
        writer.u32(chunk.mimeIdx)
        writer.u32(chunk.flags)
        writer.u32(UInt32(chunk.data.count))
        writer.bytes(chunk.data)
        return writer.data
    }

    public static func decodeSelChunk(_ data: Data) throws -> GuiSelChunk {
        guard data.count >= selChunkPrefix else {
            throw MSLError.framing("selection chunk shorter than 16-byte prefix")
        }
        var reader = GuiReader(data)
        let serial = try reader.u32()
        let mimeIdx = try reader.u32()
        let flags = try reader.u32()
        let len = try reader.u32()
        guard len <= selChunkMax else {
            throw MSLError.protocolMismatch("chunk length exceeds 256 KiB")
        }
        let payload = try reader.take(Int(len))
        guard reader.remaining == 0 else {
            throw MSLError.framing("selection chunk has trailing bytes")
        }
        assert(payload.count == Int(len), "chunk payload length matches header")
        assert(len <= selChunkMax, "chunk length within cap")
        return GuiSelChunk(serial: serial, mimeIdx: mimeIdx, flags: flags, data: payload)
    }
}
