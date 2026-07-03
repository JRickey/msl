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
    format: UInt32 = 1, scaleE12: UInt32 = 4096, rects: [RectSpec], pixels: [UInt8],
    tClient: UInt64 = 111, tSend: UInt64 = 222
) -> Data {
    var bytes = le32(win) + le32(seq) + le32(width) + le32(height) + le32(stride) + le32(format)
    bytes += le32(scaleE12) + le32(UInt32(rects.count)) + le64(tClient) + le64(tSend)
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

final class GuiCommitParserTests: XCTestCase {
    func testValidCommitParses() throws {
        let commit = try GuiProto.parseCommit(
            buildCommit(
                rects: [RectSpec(originX: 0, originY: 0, width: 2, height: 2)],
                pixels: [UInt8](repeating: 7, count: 16)))
        XCTAssertEqual(commit.win, 1)
        XCTAssertEqual(commit.seq, 7)
        XCTAssertEqual(commit.rects.count, 1)
        XCTAssertEqual(commit.pixels.count, 16)
        XCTAssertEqual(commit.scale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(commit.tClientCommitNs, 111)
        XCTAssertEqual(commit.tSendNs, 222)
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
