import XCTest

@testable import msl

final class DaemonCommandTests: XCTestCase {
    func testOmittedOverridesRemainOptional() throws {
        let command = try DaemonRunCommand.parse([])

        XCTAssertNil(command.idleTimeout)
        XCTAssertNil(command.cpus)
        XCTAssertNil(command.memoryMib)
        XCTAssertFalse(command.shareHome)
        XCTAssertFalse(command.noShareHome)
        XCTAssertFalse(command.interop)
        XCTAssertFalse(command.noInterop)
    }

    func testPositiveFlagSpellingsParse() throws {
        let command = try DaemonRunCommand.parse(["--share-home", "--interop"])

        XCTAssertTrue(command.shareHome)
        XCTAssertFalse(command.noShareHome)
        XCTAssertTrue(command.interop)
        XCTAssertFalse(command.noInterop)
    }

    func testNegativeFlagSpellingsParse() throws {
        let command = try DaemonRunCommand.parse(["--no-share-home", "--no-interop"])

        XCTAssertFalse(command.shareHome)
        XCTAssertTrue(command.noShareHome)
        XCTAssertFalse(command.interop)
        XCTAssertTrue(command.noInterop)
    }

    func testContradictoryBooleanFlagsAreRejected() {
        XCTAssertThrowsError(
            try DaemonRunCommand.parse(["--share-home", "--no-share-home"]))
        XCTAssertThrowsError(try DaemonRunCommand.parse(["--interop", "--no-interop"]))
    }

    func testExactNumericBoundsParse() throws {
        let minimum = try DaemonRunCommand.parse(
            ["--cpus", "1", "--memory-mib", "1024", "--idle-timeout", "0"])
        let maximum = try DaemonRunCommand.parse(
            ["--cpus", "64", "--memory-mib", "65536", "--idle-timeout", "86400"])

        XCTAssertEqual(minimum.cpus, 1)
        XCTAssertEqual(minimum.memoryMib, 1024)
        XCTAssertEqual(minimum.idleTimeout, 0)
        XCTAssertEqual(maximum.cpus, 64)
        XCTAssertEqual(maximum.memoryMib, 65536)
        XCTAssertEqual(maximum.idleTimeout, 86400)
    }

    func testOutOfRangeNumericOverridesAreRejectedDuringParsing() {
        XCTAssertThrowsError(try DaemonRunCommand.parse(["--cpus", "0"]))
        XCTAssertThrowsError(try DaemonRunCommand.parse(["--cpus", "65"]))
        XCTAssertThrowsError(try DaemonRunCommand.parse(["--memory-mib", "1023"]))
        XCTAssertThrowsError(try DaemonRunCommand.parse(["--memory-mib", "65537"]))
        XCTAssertThrowsError(try DaemonRunCommand.parse(["--idle-timeout", "-1"]))
        XCTAssertThrowsError(try DaemonRunCommand.parse(["--idle-timeout", "86401"]))
    }
}
