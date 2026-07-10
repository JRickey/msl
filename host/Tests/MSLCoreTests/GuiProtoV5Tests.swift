import Foundation
import XCTest

@testable import MSLCore

private func le32(_ value: UInt32) -> [UInt8] {
    return [
        UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff),
    ]
}

private func le64(_ value: UInt64) -> [UInt8] {
    return le32(UInt32(value & 0xffff_ffff)) + le32(UInt32((value >> 32) & 0xffff_ffff))
}

private struct SelWire {
    var serial: UInt32 = 0
    var origin: UInt32 = 0
    var count: UInt32 = 0
    var flags: UInt32 = 0
    var totalLen: UInt64 = 0
    var descs: [(UInt32, UInt32)] = []
    var mimes: [[UInt8]] = []
    var payloads: [[UInt8]] = []
}

private func rawSel(_ wire: SelWire) -> Data {
    var bytes = le32(wire.serial) + le32(wire.origin) + le32(wire.count) + le32(wire.flags)
    bytes += le64(wire.totalLen)
    for desc in wire.descs { bytes += le32(desc.0) + le32(desc.1) }
    for mime in wire.mimes { bytes += mime }
    for payload in wire.payloads { bytes += payload }
    return Data(bytes)
}

private struct CursorWire {
    var win: UInt32 = 1
    var width: UInt32
    var height: UInt32
    var hotspotX: UInt32 = 0
    var hotspotY: UInt32 = 0
    var scale: UInt32 = 4096
    var pixels: [UInt8] = []
}

private func rawCursor(_ wire: CursorWire) -> Data {
    var bytes = le32(wire.win) + le32(wire.width) + le32(wire.height) + le32(wire.hotspotX)
    bytes += le32(wire.hotspotY) + le32(wire.scale) + wire.pixels
    return Data(bytes)
}

final class GuiProtoV5MetaTests: XCTestCase {
    func testProtocolVersionIsFive() {
        XCTAssertEqual(GuiProto.version, 5)
    }

    func testNewTypeRawValues() {
        XCTAssertEqual(GuiType.selOffer.rawValue, 25)
        XCTAssertEqual(GuiType.hostSel.rawValue, 26)
        XCTAssertEqual(GuiType.selDataHostToGuest.rawValue, 36)
    }
}

final class GuiWinNewIdentityTests: XCTestCase {
    func testFullRoundTrip() throws {
        let value = GuiWinNew(
            win: 3, appID: "org.gnome.app", title: "Files", width: 800, height: 600, scale: 2,
            x11: true, pid: 4242, windowClass: "Gimp", instance: "gimp", transientFor: 7,
            modal: false)
        let data = try GuiProto.encode(value)
        XCTAssertEqual(try GuiProto.decode(GuiWinNew.self, from: data), value)
    }

    func testControlCharsInTitleStripped() throws {
        let value = GuiWinNew(win: 1, appID: "a", title: "AB\nC", width: 1, height: 1, scale: 1)
        let back = try GuiProto.decode(GuiWinNew.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back.title, "ABC")
    }

    func testControlCharsInClassStripped() throws {
        let value = GuiWinNew(
            win: 1, appID: "a", title: "t", width: 1, height: 1, scale: 1, windowClass: "X\u{1}Y")
        let back = try GuiProto.decode(GuiWinNew.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back.windowClass, "XY")
    }

    func testStringCapped() throws {
        let long = String(repeating: "a", count: GuiProto.winStrMax + 50)
        let value = GuiWinNew(win: 1, appID: "a", title: long, width: 1, height: 1, scale: 1)
        let back = try GuiProto.decode(GuiWinNew.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back.title.utf8.count, GuiProto.winStrMax)
    }
}

final class GuiHelloAckOutputTests: XCTestCase {
    func testOutputRoundTrip() throws {
        let value = GuiHelloAck(version: 5, scale: 2, refreshHz: 60, outputW: 1920, outputH: 1080)
        let back = try GuiProto.decode(GuiHelloAck.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back, value)
    }

    func testAbsentOutputDecodes() throws {
        let json = #"{"version":5,"scale":1.0,"refresh_hz":60}"#
        let back = try GuiProto.decode(GuiHelloAck.self, from: Data(json.utf8))
        XCTAssertNil(back.outputW)
    }

    func testRejectsZeroOutput() {
        let json = #"{"version":5,"scale":1.0,"refresh_hz":60,"output_w":0}"#
        XCTAssertThrowsError(try GuiProto.decode(GuiHelloAck.self, from: Data(json.utf8)))
    }

    func testRejectsOverMaxOutput() {
        let json = #"{"version":5,"scale":1.0,"refresh_hz":60,"output_h":16385}"#
        XCTAssertThrowsError(try GuiProto.decode(GuiHelloAck.self, from: Data(json.utf8)))
    }
}

final class GuiSelOfferCodecTests: XCTestCase {
    func testInlineRoundTrip() throws {
        let offer = GuiSelOffer(
            serial: 1, origin: 2, flags: GuiProto.selFlagInline, totalLen: 5,
            entries: [GuiSelEntry(mime: "text/plain", dataLen: 5, data: Data("hello".utf8))])
        let back = try GuiProto.decodeSelOffer(try GuiProto.encodeSelOffer(offer))
        XCTAssertEqual(back, offer)
    }

    func testStreamedRoundTrip() throws {
        let offer = GuiSelOffer(
            serial: 9, origin: 4, flags: 0, totalLen: 100,
            entries: [GuiSelEntry(mime: "image/png", dataLen: 100, data: Data())])
        let back = try GuiProto.decodeSelOffer(try GuiProto.encodeSelOffer(offer))
        XCTAssertEqual(back, offer)
    }

    func testClearedRoundTrip() throws {
        let offer = GuiSelOffer(
            serial: 3, origin: 1, flags: GuiProto.selFlagInline, totalLen: 0, entries: [])
        let data = try GuiProto.encodeSelOffer(offer)
        XCTAssertEqual(data.count, GuiProto.selOfferPrefix)
        XCTAssertEqual(try GuiProto.decodeSelOffer(data), offer)
    }

    func testRejectsOversizeTotalLen() {
        let over = UInt32(GuiProto.selStreamMax + 1)
        let data = rawSel(
            SelWire(
                count: 1, totalLen: GuiProto.selStreamMax + 1, descs: [(10, over)],
                mimes: [Array("text/plain".utf8)]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsTooManyEntries() {
        let data = rawSel(SelWire(count: GuiProto.selMaxEntries + 1))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsTotalLenMismatch() {
        let data = rawSel(
            SelWire(count: 1, totalLen: 6, descs: [(10, 5)], mimes: [Array("text/plain".utf8)]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsInlineOver64k() {
        let over = UInt32(GuiProto.selInlineMax + 1)
        let data = rawSel(
            SelWire(
                count: 1, flags: GuiProto.selFlagInline, totalLen: GuiProto.selInlineMax + 1,
                descs: [(10, over)], mimes: [Array("text/plain".utf8)]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsTrailingBytes() throws {
        let offer = GuiSelOffer(
            serial: 1, origin: 1, flags: GuiProto.selFlagInline, totalLen: 2,
            entries: [GuiSelEntry(mime: "text/plain", dataLen: 2, data: Data("hi".utf8))])
        var data = try GuiProto.encodeSelOffer(offer)
        data.append(0)
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsShortBuffer() throws {
        let offer = GuiSelOffer(
            serial: 1, origin: 1, flags: GuiProto.selFlagInline, totalLen: 2,
            entries: [GuiSelEntry(mime: "text/plain", dataLen: 2, data: Data("hi".utf8))])
        var data = try GuiProto.encodeSelOffer(offer)
        data.removeLast()
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsNonUtf8Mime() {
        let data = rawSel(SelWire(count: 1, descs: [(2, 0)], mimes: [[0xFF, 0xFE]]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsDuplicateMime() {
        let plain = Array("text/plain".utf8)
        let data = rawSel(SelWire(count: 2, descs: [(10, 0), (10, 0)], mimes: [plain, plain]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsMimeOutsideAllowlist() {
        let data = rawSel(SelWire(count: 1, descs: [(9, 0)], mimes: [Array("text/html".utf8)]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsEmptyWithNonzeroTotal() {
        let data = rawSel(SelWire(count: 0, totalLen: 5))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }
}

final class GuiSelChunkCursorTests: XCTestCase {
    func testChunkRoundTrip() throws {
        let chunk = GuiSelChunk(
            serial: 7, mimeIdx: 1, flags: GuiProto.selFlagFinal, data: Data("payload".utf8))
        let back = try GuiProto.decodeSelChunk(try GuiProto.encodeSelChunk(chunk))
        XCTAssertEqual(back, chunk)
        XCTAssertTrue(back.isFinal)
    }

    func testChunkRejectsOversizeLen() {
        let bytes = le32(0) + le32(0) + le32(0) + le32(GuiProto.selChunkMax + 1)
        XCTAssertThrowsError(try GuiProto.decodeSelChunk(Data(bytes)))
    }

    func testSelReadRoundTrip() throws {
        let value = GuiSelRead(serial: 5, mime: "text/plain", cancel: false)
        let back = try GuiProto.decode(GuiSelRead.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back, value)
    }

    func testCursorRoundTrip() throws {
        let cursor = GuiCursorImage(
            win: 1, width: 2, height: 2, hotspotX: 1, hotspotY: 1, scaleE12: 4096,
            pixels: Data([UInt8](repeating: 0xAB, count: 16)))
        let back = try GuiProto.decodeCursorImage(try GuiProto.encodeCursorImage(cursor))
        XCTAssertEqual(back, cursor)
    }

    func testCursorRejectsZeroWidth() {
        XCTAssertThrowsError(
            try GuiProto.decodeCursorImage(rawCursor(CursorWire(width: 0, height: 2))))
    }

    func testCursorRejectsOverMaxDim() {
        XCTAssertThrowsError(
            try GuiProto.decodeCursorImage(rawCursor(CursorWire(width: 513, height: 2))))
    }

    func testCursorRejectsHotspotBeyondBounds() {
        let wire = CursorWire(
            width: 2, height: 2, hotspotX: 2, pixels: [UInt8](repeating: 0, count: 16))
        XCTAssertThrowsError(try GuiProto.decodeCursorImage(rawCursor(wire)))
    }

    func testCursorRejectsPixelLengthMismatch() {
        let wire = CursorWire(width: 2, height: 2, pixels: [UInt8](repeating: 0, count: 8))
        XCTAssertThrowsError(try GuiProto.decodeCursorImage(rawCursor(wire)))
    }
}

final class GuiV5JsonTests: XCTestCase {
    func testSetLayoutRoundTrip() throws {
        let value = GuiSetLayout(layout: "us", variant: "intl")
        let back = try GuiProto.decode(GuiSetLayout.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back, value)
    }

    func testSetLayoutRejectsSlash() {
        let json = #"{"layout":"us/intl","variant":""}"#
        XCTAssertThrowsError(try GuiProto.decode(GuiSetLayout.self, from: Data(json.utf8)))
    }

    func testErrorRoundTrip() throws {
        let value = GuiErrorMsg(code: .oversizeFrame, reason: "frame too large")
        let back = try GuiProto.decode(GuiErrorMsg.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back, value)
    }

    func testErrorReasonControlCharsStripped() throws {
        let value = GuiErrorMsg(code: .policy, reason: "denied\n")
        let back = try GuiProto.decode(GuiErrorMsg.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back.reason, "denied")
    }

    func testErrorRejectsUnknownCode() {
        let json = #"{"code":"nope","reason":"x"}"#
        XCTAssertThrowsError(try GuiProto.decode(GuiErrorMsg.self, from: Data(json.utf8)))
    }

    func testTextInputStateRoundTrip() throws {
        let value = GuiTextInputState(
            win: 1, serial: 4, enabled: true,
            surrounding: GuiSurrounding(text: "hello", cursor: 5, anchor: 5), changeCause: 0,
            contentHint: 1, contentPurpose: 2,
            cursorRect: GuiCursorRect(posX: 1, posY: 2, width: 3, height: 4))
        let back = try GuiProto.decode(GuiTextInputState.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back, value)
    }

    func testTextInputStateRejectsOversizeText() throws {
        let long = String(repeating: "a", count: GuiProto.textFieldMax + 1)
        let value = GuiTextInputState(
            win: 1, serial: 1, enabled: true,
            surrounding: GuiSurrounding(text: long, cursor: 0, anchor: 0), changeCause: 0,
            contentHint: 0, contentPurpose: 0, cursorRect: nil)
        let data = try GuiProto.encode(value)
        XCTAssertThrowsError(try GuiProto.decode(GuiTextInputState.self, from: data))
    }

    func testTextInputStateRejectsCursorPastEnd() {
        let json =
            #"{"win":1,"serial":1,"enabled":true,"change_cause":0,"content_hint":0,"#
            + #""content_purpose":0,"surrounding":{"text":"hi","cursor":3,"anchor":0}}"#
        XCTAssertThrowsError(try GuiProto.decode(GuiTextInputState.self, from: Data(json.utf8)))
    }

    func testTextInputApplyRoundTrip() throws {
        let value = GuiTextInputApply(
            win: 2, serial: 9, preedit: GuiPreedit(text: "abc", cursorBegin: 0, cursorEnd: 3),
            commitText: "done", deleteBefore: 1, deleteAfter: 0)
        let back = try GuiProto.decode(GuiTextInputApply.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back, value)
    }

    func testTextInputApplyRejectsOversizeCommit() throws {
        let long = String(repeating: "a", count: GuiProto.textFieldMax + 1)
        let value = GuiTextInputApply(
            win: 1, serial: 1, preedit: nil, commitText: long, deleteBefore: 0, deleteAfter: 0)
        let data = try GuiProto.encode(value)
        XCTAssertThrowsError(try GuiProto.decode(GuiTextInputApply.self, from: data))
    }
}
