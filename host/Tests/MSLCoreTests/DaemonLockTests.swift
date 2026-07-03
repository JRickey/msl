import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class DaemonLockTests: XCTestCase {
    private func tempPath() -> String {
        return "/tmp/msl-daemonlock-\(UUID().uuidString).lock"
    }

    func testWinnerAcquiresLoserRefused() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let winner = try DaemonLock.acquire(path: path)
        defer { winner.release() }
        XCTAssertEqual(winner.path, path)
        XCTAssertThrowsError(try DaemonLock.acquire(path: path)) { error in
            let message = (error as? MSLError)?.description ?? "\(error)"
            XCTAssertTrue(message.contains("already running"), message)
        }
    }

    func testReleaseAllowsReacquire() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try DaemonLock.acquire(path: path)
        first.release()
        let second = try DaemonLock.acquire(path: path)
        second.release()
    }

    func testDeinitReleasesLock() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let held = try DaemonLock.acquire(path: path)
            XCTAssertEqual(held.path, path)
        }
        let reacquired = try DaemonLock.acquire(path: path)
        reacquired.release()
    }
}
