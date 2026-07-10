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

final class GuiSelOfferRejectionTests: XCTestCase {
    func testRejectsMimeLenOver128() {
        let data = rawSel(SelWire(count: 1, descs: [(GuiProto.selMaxMimeLen + 1, 0)]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsStreamedTrailingPayload() {
        let data = rawSel(
            SelWire(
                count: 1, flags: 0, totalLen: 5, descs: [(10, 5)],
                mimes: [Array("text/plain".utf8)], payloads: [Array("hello".utf8)]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testRejectsShortPrefix() {
        XCTAssertThrowsError(
            try GuiProto.decodeSelOffer(Data([UInt8](repeating: 0, count: 10))))
    }

    func testRejectsShortDescriptor() {
        let data = rawSel(SelWire(count: 2, descs: [(10, 0)]))
        XCTAssertThrowsError(try GuiProto.decodeSelOffer(data))
    }

    func testEncodeRejectsInlineOver64k() {
        let big = Data([UInt8](repeating: 0, count: Int(GuiProto.selInlineMax) + 1))
        let entry = GuiSelEntry(
            mime: "text/plain", dataLen: UInt32(GuiProto.selInlineMax + 1), data: big)
        let offer = GuiSelOffer(
            serial: 1, origin: 1, flags: GuiProto.selFlagInline,
            totalLen: GuiProto.selInlineMax + 1, entries: [entry])
        XCTAssertThrowsError(try GuiProto.encodeSelOffer(offer))
    }

    func testEncodeRejectsStreamedOver32m() {
        let entry = GuiSelEntry(
            mime: "image/png", dataLen: UInt32(GuiProto.selStreamMax + 1), data: Data())
        let offer = GuiSelOffer(
            serial: 1, origin: 1, flags: 0, totalLen: GuiProto.selStreamMax + 1, entries: [entry])
        XCTAssertThrowsError(try GuiProto.encodeSelOffer(offer))
    }
}

final class GuiSelChunkRejectionTests: XCTestCase {
    func testChunkRejectsTrailingBytes() throws {
        let chunk = GuiSelChunk(serial: 1, mimeIdx: 0, flags: 0, data: Data("hi".utf8))
        var data = try GuiProto.encodeSelChunk(chunk)
        data.append(0)
        XCTAssertThrowsError(try GuiProto.decodeSelChunk(data))
    }
}

final class GuiCursorRejectionTests: XCTestCase {
    func testRejectsZeroHeight() {
        XCTAssertThrowsError(
            try GuiProto.decodeCursorImage(rawCursor(CursorWire(width: 2, height: 0))))
    }

    func testRejectsHeightOverMax() {
        XCTAssertThrowsError(
            try GuiProto.decodeCursorImage(rawCursor(CursorWire(width: 2, height: 513))))
    }

    func testRejectsHotspotYBeyondBounds() {
        let wire = CursorWire(
            width: 2, height: 2, hotspotY: 2, pixels: [UInt8](repeating: 0, count: 16))
        XCTAssertThrowsError(try GuiProto.decodeCursorImage(rawCursor(wire)))
    }
}

final class GuiV5JsonRejectionTests: XCTestCase {
    func testSetLayoutRejectsLongToken() {
        let long = String(repeating: "a", count: GuiProto.layoutNameMax + 1)
        let json = "{\"layout\":\"\(long)\",\"variant\":\"\"}"
        XCTAssertThrowsError(try GuiProto.decode(GuiSetLayout.self, from: Data(json.utf8)))
    }

    func testErrorReasonCappedAt256() throws {
        let long = String(repeating: "a", count: GuiProto.errReasonMax + 100)
        let value = GuiErrorMsg(code: .policy, reason: long)
        let back = try GuiProto.decode(GuiErrorMsg.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back.reason.utf8.count, GuiProto.errReasonMax)
    }

    func testWinNewAppIdControlStripped() throws {
        let value = GuiWinNew(win: 1, appID: "a\u{1}b", title: "t", width: 1, height: 1, scale: 1)
        let back = try GuiProto.decode(GuiWinNew.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back.appID, "ab")
    }

    func testWinNewInstanceControlStripped() throws {
        let value = GuiWinNew(
            win: 1, appID: "a", title: "t", width: 1, height: 1, scale: 1, instance: "x\u{2}y")
        let back = try GuiProto.decode(GuiWinNew.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back.instance, "xy")
    }

    func testTextInputApplyRejectsOversizePreedit() throws {
        let long = String(repeating: "a", count: GuiProto.textFieldMax + 1)
        let value = GuiTextInputApply(
            win: 1, serial: 1, preedit: GuiPreedit(text: long, cursorBegin: 0, cursorEnd: 0),
            commitText: nil, deleteBefore: 0, deleteAfter: 0)
        let data = try GuiProto.encode(value)
        XCTAssertThrowsError(try GuiProto.decode(GuiTextInputApply.self, from: data))
    }

    func testTextInputApplyRejectsPreeditCursorOutside() throws {
        let value = GuiTextInputApply(
            win: 1, serial: 1, preedit: GuiPreedit(text: "ab", cursorBegin: 0, cursorEnd: 5),
            commitText: nil, deleteBefore: 0, deleteAfter: 0)
        let data = try GuiProto.encode(value)
        XCTAssertThrowsError(try GuiProto.decode(GuiTextInputApply.self, from: data))
    }

    func testTextInputStateRejectsZeroRectDim() {
        let json =
            #"{"win":1,"serial":1,"enabled":true,"change_cause":0,"content_hint":0,"#
            + #""content_purpose":0,"cursor_rect":{"x":0,"y":0,"w":0,"h":4}}"#
        XCTAssertThrowsError(try GuiProto.decode(GuiTextInputState.self, from: Data(json.utf8)))
    }

    func testTextInputStateRejectsRectOutOfRange() {
        let json =
            #"{"win":1,"serial":1,"enabled":true,"change_cause":0,"content_hint":0,"#
            + #""content_purpose":0,"cursor_rect":{"x":20000,"y":0,"w":3,"h":4}}"#
        XCTAssertThrowsError(try GuiProto.decode(GuiTextInputState.self, from: Data(json.utf8)))
    }

    func testTextInputStateAcceptsValidRect() throws {
        let value = GuiTextInputState(
            win: 1, serial: 1, enabled: true, surrounding: nil, changeCause: 0, contentHint: 0,
            contentPurpose: 0,
            cursorRect: GuiCursorRect(posX: -100, posY: 200, width: 2, height: 18))
        let back = try GuiProto.decode(GuiTextInputState.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back, value)
    }

    func testHelloAckFractionalRefreshRoundTrips() throws {
        let value = GuiHelloAck(version: 5, scale: 1, refreshHz: 59.94)
        let back = try GuiProto.decode(GuiHelloAck.self, from: try GuiProto.encode(value))
        XCTAssertEqual(back.refreshHz, 59.94, accuracy: 0.0001)
    }
}
