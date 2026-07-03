import Foundation
import XCTest

@testable import MSLCore

final class RemoveGuardTests: XCTestCase {
    private func makeImage() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-img-\(UUID().uuidString).img").path
        guard FileManager.default.createFile(atPath: path, contents: Data("img".utf8)) else {
            throw MSLError.io("cannot create temp image")
        }
        return path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".lock")
    }

    func testDeletesImageAndSidecarWhenUnlocked() throws {
        let path = try makeImage()
        defer { cleanup(path) }
        try ImageLock.deleteHoldingLock(imagePath: path, keepImage: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".lock"))
    }

    func testRefusesWhileSidecarLockHeld() throws {
        let path = try makeImage()
        defer { cleanup(path) }
        // Simulate a running VM: VMHost holds the image's sidecar lock.
        let held = try ImageLock.acquire(path: path)
        defer { withExtendedLifetime(held) {} }
        XCTAssertThrowsError(
            try ImageLock.deleteHoldingLock(imagePath: path, keepImage: false)
        ) { error in
            guard let mslError = error as? MSLError else {
                return XCTFail("expected MSLError, got \(error)")
            }
            XCTAssertTrue(
                mslError.description.contains("in use"),
                "unexpected message: \(mslError.description)")
        }
        // The image must survive a refused removal.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testKeepImageLeavesImageInPlace() throws {
        let path = try makeImage()
        defer { cleanup(path) }
        try ImageLock.deleteHoldingLock(imagePath: path, keepImage: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testMissingImageIsRemovable() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-absent-\(UUID().uuidString).img").path
        XCTAssertNoThrow(try ImageLock.deleteHoldingLock(imagePath: path, keepImage: false))
    }
}
