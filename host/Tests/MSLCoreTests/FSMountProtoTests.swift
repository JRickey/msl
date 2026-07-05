import Foundation
import XCTest

@testable import MSLCore

final class FSHelloTests: XCTestCase {
    func testHelloRoundTrip() throws {
        let hello = FSHello(distro: "ubuntu", mountID: "abcd", nonce: "ef01", readonly: true)
        let decoded = try FSHello.decode(try hello.encoded())
        XCTAssertEqual(decoded, hello)
        XCTAssertEqual(decoded.version, FSProto.version)
        XCTAssertEqual(decoded.op, "hello")
    }

    func testHelloUsesSnakeCaseAndShortVersionKey() throws {
        let data = try FSHello(distro: "ubuntu", mountID: "a", nonce: "b").encoded()
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"mount_id\""), json)
        XCTAssertTrue(json.contains("\"v\""), json)
    }

    func testHelloRejectsWrongOp() {
        let bytes = Data(#"{"v":1,"op":"route","distro":"u","mount_id":"a","nonce":"b"}"#.utf8)
        XCTAssertThrowsError(try FSHello.decode(bytes))
    }

    func testHelloRejectsWrongVersion() {
        let bytes = Data(#"{"v":99,"op":"hello","distro":"u","mount_id":"a","nonce":"b"}"#.utf8)
        XCTAssertThrowsError(try FSHello.decode(bytes))
    }

    func testHelloRejectsMissingFields() {
        let bytes = Data(#"{"v":1,"op":"hello","distro":"","mount_id":"a","nonce":"b"}"#.utf8)
        XCTAssertThrowsError(try FSHello.decode(bytes))
    }

    func testControlReplyRoundTrip() throws {
        let ok = try FSControlReply.decode(try FSControlReply(ok: true).encoded())
        XCTAssertTrue(ok.ok)
        let err = try FSControlReply.decode(try FSControlReply(ok: false, error: "no").encoded())
        XCTAssertFalse(err.ok)
        XCTAssertEqual(err.error, "no")
    }

    func testGuestOpenEncodesFsOpenFrame() throws {
        let data = try FSGuestOpen(distro: "ubuntu").encoded()
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"op\":\"fs_open\""), json)
        XCTAssertTrue(json.contains("\"v\":\(FSProto.version)"), json)
        XCTAssertTrue(json.contains("\"distro\":\"ubuntu\""), json)
        let decoded = try JSONDecoder().decode(FSGuestOpen.self, from: data)
        XCTAssertEqual(decoded, FSGuestOpen(distro: "ubuntu"))
    }
}

final class FSLocalProtoTests: XCTestCase {
    private func roundTrip(_ request: LocalRequest) throws -> LocalRequest {
        return try LocalRequest.decode(try request.encoded())
    }

    func testMountRequestsRoundTrip() throws {
        let cases: [LocalRequest] = [
            .mountPrepare(name: "ubuntu"),
            .mountPrepare(name: nil),
            .mountCommit(name: "ubuntu", mountpoint: "/Users/x/msl/ubuntu"),
            .mountUnmount(name: "ubuntu", force: true),
            .mountUnmount(name: "ubuntu", force: false),
            .mountStatus,
        ]
        for request in cases {
            XCTAssertEqual(try roundTrip(request), request)
        }
    }

    func testMountPrepareReplyRoundTrip() throws {
        let data = MountPrepareData(
            name: "ubuntu", url: "msl://ubuntu?mount=a&nonce=b",
            mountpoint: "/Users/x/msl/ubuntu", mountID: "a", nonce: "b")
        let encoded = try LocalReply.ok(data)
        let decoded = try LocalResponse<MountPrepareData>.decode(encoded)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.data, data)
        let json = String(bytes: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"mount_id\""), json)
    }

    func testMountStatusReplyRoundTrip() throws {
        let status = MountStatusData(mounts: [
            MountEntry(name: "ubuntu", mountpoint: "/Users/x/msl/ubuntu", state: "mounted"),
            MountEntry(name: "debian", mountpoint: "/Users/x/msl/debian", state: "prepared"),
        ])
        let decoded = try LocalResponse<MountStatusData>.decode(try LocalReply.ok(status))
        XCTAssertEqual(decoded.data, status)
    }
}
