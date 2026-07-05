import Foundation
import XCTest

@testable import MSLCore

final class FSMountTableTests: XCTestCase {
    func testPrepareMintsDistinctHexIdentifiers() {
        let table = FSMountTable()
        let ubuntu = table.prepare(name: "ubuntu", mountpoint: "/u/msl/ubuntu", readonly: true)
        let debian = table.prepare(name: "debian", mountpoint: "/u/msl/debian", readonly: true)
        XCTAssertEqual(ubuntu.mountID.count, LocalProto.tokenHexLength)
        XCTAssertEqual(ubuntu.nonce.count, LocalProto.tokenHexLength)
        XCTAssertNotEqual(ubuntu.mountID, ubuntu.nonce)
        XCTAssertNotEqual(ubuntu.mountID, debian.mountID)
        XCTAssertNotEqual(ubuntu.nonce, debian.nonce)
        XCTAssertEqual(ubuntu.phase, .prepared)
        XCTAssertFalse(ubuntu.nonceConsumed)
    }

    func testConsumeNonceIsSingleUse() {
        let table = FSMountTable()
        let rec = table.prepare(name: "ubuntu", mountpoint: "/u/msl/ubuntu", readonly: true)
        XCTAssertTrue(table.consumeNonce(distro: "ubuntu", mountID: rec.mountID, nonce: rec.nonce))
        // replay of the same mount id + nonce is refused
        XCTAssertFalse(table.consumeNonce(distro: "ubuntu", mountID: rec.mountID, nonce: rec.nonce))
    }

    func testConsumeNonceRejectsMismatch() {
        let table = FSMountTable()
        let rec = table.prepare(name: "ubuntu", mountpoint: "/u/msl/ubuntu", readonly: true)
        XCTAssertFalse(table.consumeNonce(distro: "ubuntu", mountID: rec.mountID, nonce: "0000"))
        XCTAssertFalse(table.consumeNonce(distro: "ubuntu", mountID: "0000", nonce: rec.nonce))
        XCTAssertFalse(table.consumeNonce(distro: "other", mountID: rec.mountID, nonce: rec.nonce))
    }

    func testCommitRequiresMatchingMountpoint() throws {
        let table = FSMountTable()
        _ = table.prepare(name: "ubuntu", mountpoint: "/u/msl/ubuntu", readonly: true)
        XCTAssertThrowsError(try table.commit(name: "ubuntu", mountpoint: "/wrong"))
        try table.commit(name: "ubuntu", mountpoint: "/u/msl/ubuntu")
        XCTAssertEqual(table.record(name: "ubuntu")?.phase, .mounted)
        XCTAssertEqual(table.mountedNames(), ["ubuntu"])
    }

    func testCommitUnknownDistroThrows() {
        let table = FSMountTable()
        XCTAssertThrowsError(try table.commit(name: "ghost", mountpoint: "/u/msl/ghost"))
    }

    func testRemoveAllDrainsAndMarkFailed() throws {
        let table = FSMountTable()
        _ = table.prepare(name: "a", mountpoint: "/u/msl/a", readonly: true)
        _ = table.prepare(name: "b", mountpoint: "/u/msl/b", readonly: true)
        try table.commit(name: "a", mountpoint: "/u/msl/a")
        table.markAllFailed()
        XCTAssertEqual(table.record(name: "a")?.phase, .failed)
        XCTAssertEqual(table.record(name: "b")?.phase, .failed)
        let drained = table.removeAll()
        XCTAssertEqual(drained.map { $0.name }, ["a", "b"])
        XCTAssertTrue(table.entries().isEmpty)
    }

    func testPrepareReplacesPriorRecord() {
        let table = FSMountTable()
        let first = table.prepare(name: "ubuntu", mountpoint: "/u/msl/ubuntu", readonly: true)
        let second = table.prepare(name: "ubuntu", mountpoint: "/u/msl/ubuntu", readonly: true)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertEqual(table.entries().count, 1)
        // the stale first nonce no longer routes
        XCTAssertFalse(
            table.consumeNonce(distro: "ubuntu", mountID: first.mountID, nonce: first.nonce))
        XCTAssertTrue(
            table.consumeNonce(distro: "ubuntu", mountID: second.mountID, nonce: second.nonce))
    }
}
