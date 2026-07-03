import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class LocalSocketBindTests: XCTestCase {
    private func tempPath() -> String {
        return "/tmp/msl-sock-\(UUID().uuidString).sock"
    }

    func testFreshBindListensAndIsAlive() throws {
        let path = tempPath()
        defer { _ = Darwin.unlink(path) }
        let fd = try LocalSocket.bindListener(path: path)
        defer { _ = Darwin.close(fd) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertTrue(LocalSocket.probeAlive(path))
    }

    func testBindCreatesOwnerOnlySocket() throws {
        let path = tempPath()
        defer { _ = Darwin.unlink(path) }
        let fd = try LocalSocket.bindListener(path: path)
        defer { _ = Darwin.close(fd) }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(perms, 0o600)
    }

    func testStaleSocketRebound() throws {
        let path = tempPath()
        defer { _ = Darwin.unlink(path) }
        let first = try LocalSocket.bindListener(path: path)
        _ = Darwin.close(first)  // socket file remains, nothing accepts -> stale
        XCTAssertFalse(LocalSocket.probeAlive(path))
        let second = try LocalSocket.bindListener(path: path)
        defer { _ = Darwin.close(second) }
        XCTAssertGreaterThanOrEqual(second, 0)
        XCTAssertTrue(LocalSocket.probeAlive(path))
    }

    func testDialFailsWhenNothingListening() {
        let path = tempPath()
        XCTAssertFalse(LocalSocket.probeAlive(path))
        XCTAssertThrowsError(try LocalSocket.dial(path: path))
    }
}
