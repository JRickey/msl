import Foundation
import XCTest

@testable import MSLMenuBarCore

final class InstallQueueTests: XCTestCase {
    private func url(_ name: String) -> URL {
        return URL(fileURLWithPath: "/tmp/\(name).msl")
    }

    func testFirstSubmitStartsImmediately() {
        var queue = InstallQueue(capacity: 8)
        XCTAssertEqual(queue.submit(url("a")), .started)
        XCTAssertEqual(queue.active, url("a"))
        XCTAssertFalse(queue.isIdle)
    }

    func testSecondSubmitQueuesBehindActive() {
        var queue = InstallQueue(capacity: 8)
        XCTAssertEqual(queue.submit(url("a")), .started)
        XCTAssertEqual(queue.submit(url("b")), .queued)
        XCTAssertEqual(queue.waiting, [url("b")])
    }

    func testBacklogIsCappedAndOverflowDrops() {
        var queue = InstallQueue(capacity: 2)
        XCTAssertEqual(queue.submit(url("active")), .started)
        XCTAssertEqual(queue.submit(url("w1")), .queued)
        XCTAssertEqual(queue.submit(url("w2")), .queued)
        XCTAssertEqual(queue.submit(url("w3")), .dropped)
        XCTAssertEqual(queue.waiting.count, 2)
    }

    func testCompletePromotesInFifoOrder() {
        var queue = InstallQueue(capacity: 8)
        _ = queue.submit(url("a"))
        _ = queue.submit(url("b"))
        _ = queue.submit(url("c"))
        XCTAssertEqual(queue.complete(), url("b"))
        XCTAssertEqual(queue.complete(), url("c"))
        XCTAssertNil(queue.complete())
        XCTAssertTrue(queue.isIdle)
    }

    func testDroppedSlotReopensAfterCompletion() {
        var queue = InstallQueue(capacity: 1)
        _ = queue.submit(url("a"))
        XCTAssertEqual(queue.submit(url("b")), .queued)
        XCTAssertEqual(queue.submit(url("c")), .dropped)
        XCTAssertEqual(queue.complete(), url("b"))
        XCTAssertEqual(queue.submit(url("c")), .queued)
    }
}
