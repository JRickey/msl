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

private struct RectSpec {
    let originX: UInt32
    let originY: UInt32
    let width: UInt32
    let height: UInt32
}

private func buildCommit(
    win: UInt32 = 1, seq: UInt32 = 7, width: UInt32 = 4, height: UInt32 = 4, stride: UInt32 = 16,
    format: UInt32 = 1, scaleE12: UInt32 = 4096, serial: UInt32 = 0, reserved: UInt32 = 0,
    rects: [RectSpec], pixels: [UInt8], tClient: UInt64 = 111, tSend: UInt64 = 222
) -> Data {
    var bytes = le32(win) + le32(seq) + le32(width) + le32(height) + le32(stride) + le32(format)
    bytes += le32(scaleE12) + le32(UInt32(rects.count)) + le32(serial) + le32(reserved)
    bytes += le64(tClient) + le64(tSend)
    for rect in rects {
        bytes += le32(rect.originX) + le32(rect.originY) + le32(rect.width) + le32(rect.height)
    }
    bytes += pixels
    return Data(bytes)
}

private func jsonString(_ value: some Encodable) throws -> String {
    return String(bytes: try GuiProto.encode(value), encoding: .utf8) ?? ""
}

final class GuiFrameHeaderTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        let header = try GuiProto.header(type: 13, flags: 0, payloadLen: 4096)
        XCTAssertEqual(header.count, GuiProto.headerSize)
        let parsed = try GuiProto.parseHeader(header)
        XCTAssertEqual(parsed.type, 13)
        XCTAssertEqual(parsed.flags, 0)
        XCTAssertEqual(parsed.len, 4096)
    }

    func testHeaderRejectsOversizePayloadOnEncode() {
        XCTAssertThrowsError(
            try GuiProto.header(type: 1, flags: 0, payloadLen: GuiProto.maxFrame + 1))
    }

    func testParseHeaderRejectsOversizeLength() {
        let bytes = le32(13) + le32(0) + le64(UInt64(GuiProto.maxFrame) + 1)
        XCTAssertThrowsError(try GuiProto.parseHeader(Data(bytes)))
    }

    func testParseHeaderRejectsWrongSize() {
        XCTAssertThrowsError(try GuiProto.parseHeader(Data([0, 1, 2, 3])))
    }
}

final class GuiReaderSliceTests: XCTestCase {
    func testTakePreservesSliceIndicesAcrossMultipleReads() throws {
        let storage = Data([99, 98, 1, 2, 4, 3, 2, 1, 7, 8, 9, 10, 97])
        var reader = GuiReader(storage[2..<12])

        let first = try reader.take(2)
        let value = try reader.u32()
        let second = try reader.take(4)

        XCTAssertEqual(first.startIndex, 2)
        XCTAssertEqual(Array(first), [1, 2])
        XCTAssertEqual(value, 0x0102_0304)
        XCTAssertEqual(second.startIndex, 8)
        XCTAssertEqual(Array(second), [7, 8, 9, 10])
        XCTAssertEqual(reader.offset, 10)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testTakenSlicesOutliveReaderAndRejectUnderflow() throws {
        let slices: (Data, Data) = try {
            let storage = Data([0, 11, 12, 13, 14, 15, 16, 17])
            var reader = GuiReader(storage[1..<8])
            let first = try reader.take(3)
            let second = try reader.take(4)
            XCTAssertThrowsError(try reader.take(1))
            return (first, second)
        }()

        XCTAssertEqual(Array(slices.0), [11, 12, 13])
        XCTAssertEqual(Array(slices.1), [14, 15, 16, 17])
        XCTAssertEqual(slices.0.startIndex, 1)
        XCTAssertEqual(slices.1.startIndex, 4)
    }
}

final class GuiControlCodecTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        return try GuiProto.decode(T.self, from: try GuiProto.encode(value))
    }

    func testHelloRoundTrip() throws {
        let value = GuiHello(version: 1, distro: "ubuntu")
        XCTAssertEqual(try roundTrip(value), value)
    }

    func testHelloAckRoundTripAndKeys() throws {
        let value = GuiHelloAck(version: 1, scale: 2.0, refreshHz: 120)
        XCTAssertEqual(try roundTrip(value), value)
        XCTAssertTrue(try jsonString(value).contains("\"refresh_hz\""))
    }

    func testWinNewRoundTripAndKeys() throws {
        let value = GuiWinNew(
            win: 3, appID: "org.gnome.app", title: "Files", width: 800, height: 600, scale: 2)
        XCTAssertEqual(try roundTrip(value), value)
        let json = try jsonString(value)
        XCTAssertTrue(json.contains("\"app_id\""), json)
        XCTAssertTrue(json.contains("\"w\""), json)
        XCTAssertTrue(json.contains("\"h\""), json)
    }

    func testWindowRefAndTitleAndCursor() throws {
        XCTAssertEqual(try roundTrip(GuiWinRef(win: 9)), GuiWinRef(win: 9))
        XCTAssertEqual(
            try roundTrip(GuiWinTitle(win: 9, title: "T")), GuiWinTitle(win: 9, title: "T"))
        XCTAssertEqual(
            try roundTrip(GuiCursorNamed(win: 9, name: "text")),
            GuiCursorNamed(win: 9, name: "text"))
    }

    func testConfigureAndCloseRoundTrip() throws {
        let cfg = GuiConfigure(
            win: 2, width: 640, height: 480, serial: 5, states: ["activated", "resizing"])
        XCTAssertEqual(try roundTrip(cfg), cfg)
        XCTAssertEqual(try roundTrip(GuiClose(win: 2)), GuiClose(win: 2))
    }

    func testPointerRoundTripAndKeys() throws {
        let value = GuiPointer(
            win: 1, kind: "button", posX: 12.5, posY: 8.25, button: GuiButton.left, state: 1,
            dx: 0, dy: 0, tHostNs: 99)
        XCTAssertEqual(try roundTrip(value), value)
        let json = try jsonString(value)
        XCTAssertTrue(json.contains("\"t_host_ns\""), json)
        XCTAssertTrue(json.contains("\"x\""), json)
    }

    func testKeyAndPresentAckRoundTripAndKeys() throws {
        let key = GuiKey(win: 1, keycode: 30, state: 1, tHostNs: 42)
        XCTAssertEqual(try roundTrip(key), key)
        let ack = GuiPresentAck(win: 1, seq: 3, tRecvNs: 10, tPresentNs: 20)
        XCTAssertEqual(try roundTrip(ack), ack)
        let json = try jsonString(ack)
        XCTAssertTrue(json.contains("\"t_recv_ns\""), json)
        XCTAssertTrue(json.contains("\"t_present_ns\""), json)
    }

    func testDecodeRejectsEmptyPayload() {
        XCTAssertThrowsError(try GuiProto.decode(GuiHello.self, from: Data()))
    }
}

final class GuiPopupCodecTests: XCTestCase {
    func testPopupNewRoundTripAndKeys() throws {
        let value = GuiPopupNew(
            win: 5, parent: 3, posX: -12, posY: 40, width: 200, height: 150, scale: 2)
        let data = try GuiProto.encode(value)
        XCTAssertEqual(try GuiProto.decode(GuiPopupNew.self, from: data), value)
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"parent\""), json)
        XCTAssertTrue(json.contains("\"w\""), json)
        XCTAssertTrue(json.contains("\"h\""), json)
    }

    func testPopupNewDecodesSnakeCaseJSON() throws {
        let json = #"{"win":5,"parent":3,"x":-12,"y":40,"w":200,"h":150,"scale":2.0}"#
        let msg = try GuiProto.decode(GuiPopupNew.self, from: Data(json.utf8))
        XCTAssertEqual(msg.win, 5)
        XCTAssertEqual(msg.parent, 3)
        XCTAssertEqual(msg.posX, -12)
        XCTAssertEqual(msg.posY, 40)
        XCTAssertEqual(msg.width, 200)
        XCTAssertEqual(msg.height, 150)
    }

    func testPopupMovedRoundTripAndKeys() throws {
        let value = GuiPopupMoved(win: 5, posX: 7, posY: -3)
        XCTAssertEqual(
            try GuiProto.decode(GuiPopupMoved.self, from: try GuiProto.encode(value)), value)
        let json = #"{"win":5,"x":7,"y":-3}"#
        let msg = try GuiProto.decode(GuiPopupMoved.self, from: Data(json.utf8))
        XCTAssertEqual(msg, value)
    }

    func testPopupDismissRoundTrip() throws {
        let value = GuiPopupDismiss(win: 9)
        XCTAssertEqual(
            try GuiProto.decode(GuiPopupDismiss.self, from: try GuiProto.encode(value)), value)
        let msg = try GuiProto.decode(GuiPopupDismiss.self, from: Data(#"{"win":9}"#.utf8))
        XCTAssertEqual(msg.win, 9)
    }
}

final class GuiWinLimitsTests: XCTestCase {
    func testWinLimitsRoundTrip() throws {
        let msg = GuiWinLimits(win: 4, minWidth: 1365, minHeight: 792, maxWidth: 0, maxHeight: 0)
        let data = try GuiProto.encode(msg)
        let back = try GuiProto.decode(GuiWinLimits.self, from: data)
        XCTAssertEqual(back, msg)
    }

    func testWinLimitsWireKeys() throws {
        let json = #"{"win":9,"min_w":100,"min_h":50,"max_w":200,"max_h":150}"#
        let msg = try GuiProto.decode(GuiWinLimits.self, from: Data(json.utf8))
        XCTAssertEqual(msg.minWidth, 100)
        XCTAssertEqual(msg.maxHeight, 150)
    }
}

final class GuiCommitParserTests: XCTestCase {
    func testValidCommitParses() throws {
        let commit = try GuiProto.parseCommit(
            buildCommit(
                serial: 5,
                rects: [RectSpec(originX: 0, originY: 0, width: 2, height: 2)],
                pixels: [UInt8](repeating: 7, count: 16)))
        XCTAssertEqual(commit.win, 1)
        XCTAssertEqual(commit.seq, 7)
        XCTAssertEqual(commit.serial, 5)
        XCTAssertEqual(commit.rects.count, 1)
        XCTAssertEqual(commit.pixels.count, 16)
        XCTAssertEqual(commit.scale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(commit.tClientCommitNs, 111)
        XCTAssertEqual(commit.tSendNs, 222)
    }

    func testSerialLandsAndReservedIgnored() throws {
        let commit = try GuiProto.parseCommit(
            buildCommit(
                serial: 42, reserved: 0xdead_beef,
                rects: [RectSpec(originX: 0, originY: 0, width: 2, height: 2)],
                pixels: [UInt8](repeating: 0, count: 16)))
        XCTAssertEqual(commit.serial, 42, "serial parses at offset 32")
    }

    func testTimestampsSurviveSerialInsertion() throws {
        let commit = try GuiProto.parseCommit(
            buildCommit(
                serial: 9,
                rects: [RectSpec(originX: 0, originY: 0, width: 2, height: 2)],
                pixels: [UInt8](repeating: 0, count: 16), tClient: 777, tSend: 888))
        XCTAssertEqual(commit.tClientCommitNs, 777, "t_client stays 8-byte aligned at offset 40")
        XCTAssertEqual(commit.tSendNs, 888, "t_send stays 8-byte aligned at offset 48")
    }

    func testRejects53ByteTruncatedHeader() {
        XCTAssertThrowsError(try GuiProto.parseCommit(Data([UInt8](repeating: 0, count: 53))))
    }

    func testRejects55ByteTruncatedHeader() {
        XCTAssertThrowsError(try GuiProto.parseCommit(Data([UInt8](repeating: 0, count: 55))))
    }

    func testMultipleRectsPackTightly() throws {
        let rects = [
            RectSpec(originX: 0, originY: 0, width: 2, height: 1),
            RectSpec(originX: 0, originY: 1, width: 1, height: 1),
        ]
        let pixels = [UInt8](repeating: 3, count: 2 * 4 + 1 * 4)
        let commit = try GuiProto.parseCommit(buildCommit(rects: rects, pixels: pixels))
        XCTAssertEqual(commit.rects.count, 2)
        XCTAssertEqual(commit.pixels.count, 12)
    }

    func testRejectsShortHeader() {
        XCTAssertThrowsError(try GuiProto.parseCommit(Data([UInt8](repeating: 0, count: 47))))
    }

    func testRejectsTooManyRects() {
        let data = buildCommit(rects: [], pixels: [])
        var bytes = [UInt8](data)
        bytes.replaceSubrange(28..<32, with: le32(UInt32(GuiProto.maxRects) + 1))
        XCTAssertThrowsError(try GuiProto.parseCommit(Data(bytes)))
    }

    func testRejectsStrideBelowWidth() {
        XCTAssertThrowsError(
            try GuiProto.parseCommit(
                buildCommit(
                    stride: 15, rects: [RectSpec(originX: 0, originY: 0, width: 2, height: 2)],
                    pixels: [UInt8](repeating: 0, count: 16))))
    }

    func testRejectsRectOutsideBuffer() {
        XCTAssertThrowsError(
            try GuiProto.parseCommit(
                buildCommit(
                    rects: [RectSpec(originX: 3, originY: 0, width: 2, height: 2)],
                    pixels: [UInt8](repeating: 0, count: 16))))
    }

    func testRejectsTruncatedPixels() {
        XCTAssertThrowsError(
            try GuiProto.parseCommit(
                buildCommit(
                    rects: [RectSpec(originX: 0, originY: 0, width: 2, height: 2)],
                    pixels: [UInt8](repeating: 0, count: 8))))
    }

    func testRejectsZeroDimension() {
        XCTAssertThrowsError(try GuiProto.parseCommit(buildCommit(width: 0, rects: [], pixels: [])))
    }

    func testRejectsUnknownFormat() {
        XCTAssertThrowsError(
            try GuiProto.parseCommit(buildCommit(format: 2, rects: [], pixels: [])))
    }

    func testRejectsTrailingBytes() {
        XCTAssertThrowsError(
            try GuiProto.parseCommit(
                buildCommit(
                    rects: [RectSpec(originX: 0, originY: 0, width: 2, height: 2)],
                    pixels: [UInt8](repeating: 0, count: 17))))
    }

    func testScaleFromE12() throws {
        let commit = try GuiProto.parseCommit(buildCommit(scaleE12: 8192, rects: [], pixels: []))
        XCTAssertEqual(commit.scale, 2.0, accuracy: 0.0001)
    }
}
