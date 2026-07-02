import XCTest

@testable import MSLCore

final class ShareSpecTests: XCTestCase {
    func testParsesReadWriteShare() throws {
        let spec = try ShareSpec.parse("mac=/Users/jack")
        XCTAssertEqual(spec, ShareSpec(tag: "mac", hostPath: "/Users/jack", readOnly: false))
    }

    func testParsesReadOnlySuffix() throws {
        let spec = try ShareSpec.parse("data=/srv/data:ro")
        XCTAssertEqual(spec, ShareSpec(tag: "data", hostPath: "/srv/data", readOnly: true))
    }

    func testPathWithEqualsKeepsRemainder() throws {
        let spec = try ShareSpec.parse("k=/a=b/c")
        XCTAssertEqual(spec.hostPath, "/a=b/c")
        XCTAssertFalse(spec.readOnly)
    }

    func testRejectsMissingEquals() {
        XCTAssertThrowsError(try ShareSpec.parse("mac"))
    }

    func testRejectsEmptyPath() {
        XCTAssertThrowsError(try ShareSpec.parse("mac="))
    }

    func testRejectsUppercaseTag() {
        XCTAssertThrowsError(try ShareSpec.parse("Mac=/tmp"))
    }

    func testRejectsLeadingDigitTag() {
        XCTAssertThrowsError(try ShareSpec.parse("1tag=/tmp"))
    }

    func testRejectsTagOverSixteenChars() {
        XCTAssertFalse(ShareSpec.isValidTag("abcdefghijklmnopq"))
        XCTAssertTrue(ShareSpec.isValidTag("abcdefghijklmnop"))
    }

    func testAcceptsDigitsAfterFirst() {
        XCTAssertTrue(ShareSpec.isValidTag("mac0share9"))
    }
}

final class CwdMapTests: XCTestCase {
    func testHomeRootMapsToShareRoot() {
        let out = mapSessionCwd(hostCwd: "/Users/jack", home: "/Users/jack", hasMacShare: true)
        XCTAssertEqual(out, "/mnt/mac")
    }

    func testSubdirMapsRelative() {
        let out = mapSessionCwd(
            hostCwd: "/Users/jack/dev/msl", home: "/Users/jack", hasMacShare: true)
        XCTAssertEqual(out, "/mnt/mac/dev/msl")
    }

    func testTrailingSlashHomeNormalized() {
        let out = mapSessionCwd(
            hostCwd: "/Users/jack/x", home: "/Users/jack/", hasMacShare: true)
        XCTAssertEqual(out, "/mnt/mac/x")
    }

    func testOutsideHomeFallsBackToRoot() {
        let out = mapSessionCwd(hostCwd: "/etc", home: "/Users/jack", hasMacShare: true)
        XCTAssertEqual(out, "/root")
    }

    func testNoShareAlwaysRoot() {
        let out = mapSessionCwd(
            hostCwd: "/Users/jack/dev", home: "/Users/jack", hasMacShare: false)
        XCTAssertEqual(out, "/root")
    }

    func testSiblingPrefixNotMatched() {
        let out = mapSessionCwd(
            hostCwd: "/Users/jackson/x", home: "/Users/jack", hasMacShare: true)
        XCTAssertEqual(out, "/root")
    }
}
