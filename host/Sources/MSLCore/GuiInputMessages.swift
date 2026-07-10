import Foundation

/// A cursor image (`cursor_image`): tightly packed ARGB8888-premultiplied
/// pixels matching the commit path's `FMT_ARGB8888`.
public struct GuiCursorImage: Sendable, Equatable {
    public let win: UInt32
    public let width: UInt32
    public let height: UInt32
    public let hotspotX: UInt32
    public let hotspotY: UInt32
    public let scaleE12: UInt32
    public let pixels: Data

    public init(
        win: UInt32, width: UInt32, height: UInt32, hotspotX: UInt32, hotspotY: UInt32,
        scaleE12: UInt32, pixels: Data
    ) {
        self.win = win
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.scaleE12 = scaleE12
        self.pixels = pixels
    }
}

/// A keymap request `set_layout {layout, variant}`; both tokens are capped at
/// 64 bytes and restricted to `[A-Za-z0-9_-]` by the decoder.
public struct GuiSetLayout: Codable, Sendable, Equatable {
    public let layout: String
    public let variant: String

    enum CodingKeys: String, CodingKey {
        case layout, variant
    }

    public init(layout: String, variant: String) {
        self.layout = layout
        self.variant = variant
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let layoutValue = try container.decode(String.self, forKey: .layout)
        let variantValue = try container.decode(String.self, forKey: .variant)
        try GuiSetLayout.checkToken(layoutValue)
        try GuiSetLayout.checkToken(variantValue)
        layout = layoutValue
        variant = variantValue
    }

    private static func checkToken(_ token: String) throws {
        assert(GuiProto.layoutNameMax > 0, "layout cap must be positive")
        guard token.utf8.count <= GuiProto.layoutNameMax else {
            throw MSLError.protocolMismatch("layout token exceeds 64 bytes")
        }
        let allowed = token.utf8.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F || byte == 0x2D
        }
        guard allowed else {
            throw MSLError.protocolMismatch("layout token has an illegal character")
        }
    }
}

/// The protocol-error taxonomy carried by `error` frames. An unknown code fails
/// decoding, so a peer cannot invent one.
public enum GuiErrorCode: String, Codable, Sendable, Equatable {
    case protocolVersion = "protocol_version"
    case malformedFrame = "malformed_frame"
    case oversizeFrame = "oversize_frame"
    case invalidDimensions = "invalid_dimensions"
    case invalidWindow = "invalid_window"
    case policy
}

/// An `error {code, reason}` frame; `reason` is sanitized and capped on decode.
public struct GuiErrorMsg: Codable, Sendable, Equatable {
    public let code: GuiErrorCode
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case code, reason
    }

    public init(code: GuiErrorCode, reason: String) {
        self.code = code
        self.reason = reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(GuiErrorCode.self, forKey: .code)
        let rawReason = try container.decode(String.self, forKey: .reason)
        reason = GuiProto.sanitize(rawReason, cap: GuiProto.errReasonMax)
    }
}

/// The surrounding-text snapshot inside a `text_input_state`.
public struct GuiSurrounding: Codable, Sendable, Equatable {
    public let text: String
    public let cursor: UInt32
    public let anchor: UInt32

    public init(text: String, cursor: UInt32, anchor: UInt32) {
        self.text = text
        self.cursor = cursor
        self.anchor = anchor
    }
}

/// A cursor rectangle in window-local logical pixels. The codec bounds only its
/// magnitude; window-relative containment is the consumer's responsibility.
public struct GuiCursorRect: Codable, Sendable, Equatable {
    public let posX: Int32
    public let posY: Int32
    public let width: UInt32
    public let height: UInt32

    enum CodingKeys: String, CodingKey {
        case posX = "x"
        case posY = "y"
        case width = "w"
        case height = "h"
    }

    public init(posX: Int32, posY: Int32, width: UInt32, height: UInt32) {
        self.posX = posX
        self.posY = posY
        self.width = width
        self.height = height
    }
}

/// Guest→host `text_input_state`: the atomic `zwp_text_input_v3` state made
/// current by the client's commit.
public struct GuiTextInputState: Codable, Sendable, Equatable {
    public let win: UInt32
    public let serial: UInt32
    public let enabled: Bool
    public let surrounding: GuiSurrounding?
    public let changeCause: UInt32
    public let contentHint: UInt32
    public let contentPurpose: UInt32
    public let cursorRect: GuiCursorRect?

    enum CodingKeys: String, CodingKey {
        case win, serial, enabled, surrounding
        case changeCause = "change_cause"
        case contentHint = "content_hint"
        case contentPurpose = "content_purpose"
        case cursorRect = "cursor_rect"
    }

    public init(
        win: UInt32, serial: UInt32, enabled: Bool, surrounding: GuiSurrounding?,
        changeCause: UInt32, contentHint: UInt32, contentPurpose: UInt32,
        cursorRect: GuiCursorRect?
    ) {
        self.win = win
        self.serial = serial
        self.enabled = enabled
        self.surrounding = surrounding
        self.changeCause = changeCause
        self.contentHint = contentHint
        self.contentPurpose = contentPurpose
        self.cursorRect = cursorRect
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        win = try container.decode(UInt32.self, forKey: .win)
        serial = try container.decode(UInt32.self, forKey: .serial)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        changeCause = try container.decode(UInt32.self, forKey: .changeCause)
        contentHint = try container.decode(UInt32.self, forKey: .contentHint)
        contentPurpose = try container.decode(UInt32.self, forKey: .contentPurpose)
        let rect = try container.decodeIfPresent(GuiCursorRect.self, forKey: .cursorRect)
        try GuiTextInputState.checkCursorRect(rect)
        cursorRect = rect
        let snapshot = try container.decodeIfPresent(GuiSurrounding.self, forKey: .surrounding)
        try GuiTextInputState.checkSurrounding(snapshot)
        surrounding = snapshot
    }

    private static func checkSurrounding(_ snapshot: GuiSurrounding?) throws {
        guard let snapshot else { return }
        guard snapshot.text.utf8.count <= GuiProto.textFieldMax else {
            throw MSLError.protocolMismatch("surrounding text exceeds 4 KiB")
        }
        let length = UInt32(snapshot.text.utf8.count)
        guard snapshot.cursor <= length, snapshot.anchor <= length else {
            throw MSLError.protocolMismatch("surrounding cursor past end of text")
        }
    }

    private static func checkCursorRect(_ rect: GuiCursorRect?) throws {
        guard let rect else { return }
        assert(GuiProto.textRectDimMax >= 1, "rect dimension ceiling is positive")
        guard (1...GuiProto.textRectDimMax).contains(rect.width) else {
            throw MSLError.protocolMismatch("cursor_rect width out of range")
        }
        guard (1...GuiProto.textRectDimMax).contains(rect.height) else {
            throw MSLError.protocolMismatch("cursor_rect height out of range")
        }
        let coordRange = -GuiProto.textRectCoordMax...GuiProto.textRectCoordMax
        guard coordRange.contains(rect.posX), coordRange.contains(rect.posY) else {
            throw MSLError.protocolMismatch("cursor_rect coordinate out of range")
        }
        assert(rect.width >= 1 && rect.height >= 1, "cursor_rect dims positive")
    }
}

/// The preedit span inside a `text_input_apply`.
public struct GuiPreedit: Codable, Sendable, Equatable {
    public let text: String
    public let cursorBegin: Int32
    public let cursorEnd: Int32

    enum CodingKeys: String, CodingKey {
        case text
        case cursorBegin = "cursor_begin"
        case cursorEnd = "cursor_end"
    }

    public init(text: String, cursorBegin: Int32, cursorEnd: Int32) {
        self.text = text
        self.cursorBegin = cursorBegin
        self.cursorEnd = cursorEnd
    }
}

/// Host→guest `text_input_apply`: one atomic input-method edit group.
public struct GuiTextInputApply: Codable, Sendable, Equatable {
    public let win: UInt32
    public let serial: UInt32
    public let preedit: GuiPreedit?
    public let commitText: String?
    public let deleteBefore: UInt32
    public let deleteAfter: UInt32

    enum CodingKeys: String, CodingKey {
        case win, serial, preedit
        case commitText = "commit_text"
        case deleteBefore = "delete_before"
        case deleteAfter = "delete_after"
    }

    public init(
        win: UInt32, serial: UInt32, preedit: GuiPreedit?, commitText: String?,
        deleteBefore: UInt32, deleteAfter: UInt32
    ) {
        self.win = win
        self.serial = serial
        self.preedit = preedit
        self.commitText = commitText
        self.deleteBefore = deleteBefore
        self.deleteAfter = deleteAfter
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        win = try container.decode(UInt32.self, forKey: .win)
        serial = try container.decode(UInt32.self, forKey: .serial)
        deleteBefore = try container.decode(UInt32.self, forKey: .deleteBefore)
        deleteAfter = try container.decode(UInt32.self, forKey: .deleteAfter)
        let commit = try container.decodeIfPresent(String.self, forKey: .commitText)
        let pre = try container.decodeIfPresent(GuiPreedit.self, forKey: .preedit)
        try GuiTextInputApply.checkBounds(commit: commit, preedit: pre)
        commitText = commit
        preedit = pre
    }

    private static func checkBounds(commit: String?, preedit: GuiPreedit?) throws {
        if let commit, commit.utf8.count > GuiProto.textFieldMax {
            throw MSLError.protocolMismatch("commit_text exceeds 4 KiB")
        }
        guard let preedit else { return }
        guard preedit.text.utf8.count <= GuiProto.textFieldMax else {
            throw MSLError.protocolMismatch("preedit text exceeds 4 KiB")
        }
        let length = Int32(preedit.text.utf8.count)
        guard preedit.cursorBegin >= 0, preedit.cursorEnd >= 0, preedit.cursorBegin <= length,
            preedit.cursorEnd <= length
        else {
            throw MSLError.protocolMismatch("preedit cursor past end of text")
        }
    }
}

extension GuiProto {
    private static func checkCursorDims(
        width: UInt32, height: UInt32, hotspotX: UInt32, hotspotY: UInt32
    ) throws {
        guard (cursorMinDim...cursorMaxDim).contains(width) else {
            throw MSLError.protocolMismatch("cursor width out of range")
        }
        guard (cursorMinDim...cursorMaxDim).contains(height) else {
            throw MSLError.protocolMismatch("cursor height out of range")
        }
        guard hotspotX < width else {
            throw MSLError.protocolMismatch("cursor hotspot_x outside image")
        }
        guard hotspotY < height else {
            throw MSLError.protocolMismatch("cursor hotspot_y outside image")
        }
    }

    private static func cursorPixelBytes(width: UInt32, height: UInt32) -> Int {
        assert(width <= cursorMaxDim, "width already validated")
        assert(height <= cursorMaxDim, "height already validated")
        return Int(width) * Int(height) * 4
    }

    public static func encodeCursorImage(_ cursor: GuiCursorImage) throws -> Data {
        try checkCursorDims(
            width: cursor.width, height: cursor.height, hotspotX: cursor.hotspotX,
            hotspotY: cursor.hotspotY)
        let need = cursorPixelBytes(width: cursor.width, height: cursor.height)
        guard cursor.pixels.count == need else {
            throw MSLError.protocolMismatch("cursor pixel length mismatch")
        }
        var writer = GuiWriter()
        writer.u32(cursor.win)
        writer.u32(cursor.width)
        writer.u32(cursor.height)
        writer.u32(cursor.hotspotX)
        writer.u32(cursor.hotspotY)
        writer.u32(cursor.scaleE12)
        writer.bytes(cursor.pixels)
        assert(writer.count == cursorPrefix + need, "cursor frame exact")
        return writer.data
    }

    public static func decodeCursorImage(_ data: Data) throws -> GuiCursorImage {
        guard data.count >= cursorPrefix else {
            throw MSLError.framing("cursor image shorter than 24-byte prefix")
        }
        var reader = GuiReader(data)
        let win = try reader.u32()
        let width = try reader.u32()
        let height = try reader.u32()
        let hotspotX = try reader.u32()
        let hotspotY = try reader.u32()
        let scaleE12 = try reader.u32()
        try checkCursorDims(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY)
        let need = cursorPixelBytes(width: width, height: height)
        let pixels = try reader.take(need)
        guard reader.remaining == 0 else {
            throw MSLError.framing("cursor image has trailing bytes")
        }
        assert(pixels.count == need, "cursor pixel length matches header")
        assert(width <= cursorMaxDim && height <= cursorMaxDim, "cursor dims bounded")
        return GuiCursorImage(
            win: win, width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY,
            scaleE12: scaleE12, pixels: pixels)
    }
}
