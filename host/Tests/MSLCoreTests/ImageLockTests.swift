import CMSLSys
import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class ImageLockTests: XCTestCase {
    private func makeTempFile() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-lock-\(UUID().uuidString)").path
        guard FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) else {
            throw MSLError.io("could not create temp file for test")
        }
        return path
    }

    func testDirectFlockRejectsSecondHolder() throws {
        let path = try makeTempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = Darwin.open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(first, 0)
        defer { _ = Darwin.close(first) }
        XCTAssertEqual(msl_flock(first, LOCK_EX | LOCK_NB), 0)

        let second = Darwin.open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(second, 0)
        defer { _ = Darwin.close(second) }
        XCTAssertEqual(msl_flock(second, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
    }

    func testImageLockAcquiresThenBlocksSecond() throws {
        let path = try makeTempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let held = try ImageLock.acquire(path: path)
        XCTAssertEqual(held.path, path)
        XCTAssertThrowsError(try ImageLock.acquire(path: path)) { error in
            guard let mslError = error as? MSLError else {
                return XCTFail("expected MSLError, got \(error)")
            }
            XCTAssertTrue(
                mslError.description.contains("image in use by another msl process"),
                "unexpected message: \(mslError.description)")
        }
        withExtendedLifetime(held) {}
    }

    func testImageLockReleasesOnDeinit() throws {
        let path = try makeTempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let first = try ImageLock.acquire(path: path)
            XCTAssertEqual(first.path, path)
        }
        // First lock dropped: its deinit closed the fd, so re-acquire succeeds.
        let second = try ImageLock.acquire(path: path)
        withExtendedLifetime(second) {}
    }

    func testImageLockRejectsMissingFile() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-absent-\(UUID().uuidString)").path
        XCTAssertThrowsError(try ImageLock.acquire(path: path))
    }
}
