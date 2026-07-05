import Foundation
import XCTest

@testable import MSLCore

final class FSMountpointTests: XCTestCase {
    private let home = "/Users/tester"

    func testBaseAndDirectory() {
        XCTAssertEqual(FSMountpoint.base(home: home), "/Users/tester/msl")
        XCTAssertEqual(
            FSMountpoint.directory(distro: "ubuntu", home: home), "/Users/tester/msl/ubuntu")
    }

    func testInvalidDistroNamesRejected() {
        for bad in ["", ".", "..", "a/b", "with\u{0}nul", String(repeating: "x", count: 256)] {
            XCTAssertFalse(FSMountpoint.isValidDistroName(bad), bad)
            XCTAssertNil(FSMountpoint.directory(distro: bad, home: home), bad)
        }
        for good in ["ubuntu", "debian-12", "my.distro", "a"] {
            XCTAssertTrue(FSMountpoint.isValidDistroName(good), good)
        }
    }

    func testValidateAcceptsExactMountpointOnly() {
        XCTAssertTrue(
            FSMountpoint.validate(
                mountpoint: "/Users/tester/msl/ubuntu", distro: "ubuntu", home: home))
        // traversal or a different location is rejected
        XCTAssertFalse(
            FSMountpoint.validate(
                mountpoint: "/Users/tester/msl/ubuntu/../../etc", distro: "ubuntu", home: home))
        XCTAssertFalse(
            FSMountpoint.validate(mountpoint: "/tmp/evil", distro: "ubuntu", home: home))
        XCTAssertFalse(
            FSMountpoint.validate(
                mountpoint: "/Users/tester/msl/debian", distro: "ubuntu", home: home))
    }

    func testResourceURLShape() throws {
        let url = try XCTUnwrap(
            FSMountpoint.resourceURL(distro: "ubuntu", mountID: "abcd", nonce: "ef01"))
        XCTAssertTrue(url.hasPrefix("msl://ubuntu?"))
        XCTAssertTrue(url.contains("mount=abcd"))
        XCTAssertTrue(url.contains("nonce=ef01"))
        // reparse via the appex-side parser proves the URL round-trips
        let parsed = try XCTUnwrap(MSLResourceURLProbe.parse(url))
        XCTAssertEqual(parsed.distro, "ubuntu")
        XCTAssertEqual(parsed.mount, "abcd")
        XCTAssertEqual(parsed.nonce, "ef01")
    }

    func testResourceURLRejectsBadInputs() {
        XCTAssertNil(FSMountpoint.resourceURL(distro: "a/b", mountID: "x", nonce: "y"))
        XCTAssertNil(FSMountpoint.resourceURL(distro: "ubuntu", mountID: "", nonce: "y"))
        XCTAssertNil(FSMountpoint.resourceURL(distro: "ubuntu", mountID: "x", nonce: ""))
    }
}

/// Local mirror of the appex URL parser so the host test can assert the URL the
/// daemon builds round-trips through the same field extraction the appex uses.
enum MSLResourceURLProbe {
    struct Parsed: Equatable {
        let distro: String
        let mount: String
        let nonce: String
    }

    static func parse(_ string: String) -> Parsed? {
        guard let comps = URLComponents(string: string), comps.scheme == "msl" else { return nil }
        guard let host = comps.host, !host.isEmpty else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String {
            items.first { $0.name == name }?.value ?? ""
        }
        return Parsed(distro: host, mount: value("mount"), nonce: value("nonce"))
    }
}
