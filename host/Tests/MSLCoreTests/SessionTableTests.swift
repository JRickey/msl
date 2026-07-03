import Foundation
import XCTest

@testable import MSLCore

final class SessionTableTokenTests: XCTestCase {
    func testConsumeReturnsRecordThenRejectsReuse() throws {
        var table = SessionTable()
        try table.add(sessionID: 1, name: "ubuntu", guestToken: "guest", localToken: "local")
        let record = try table.consumeLocalToken(sessionID: 1, token: "local")
        XCTAssertEqual(record.guestToken, "guest")
        XCTAssertEqual(record.name, "ubuntu")
        XCTAssertThrowsError(try table.consumeLocalToken(sessionID: 1, token: "local"))
    }

    func testUnknownSessionRejected() {
        var table = SessionTable()
        XCTAssertThrowsError(try table.consumeLocalToken(sessionID: 99, token: "x"))
    }

    func testWrongTokenRejected() throws {
        var table = SessionTable()
        try table.add(sessionID: 1, name: "ubuntu", guestToken: "g", localToken: "right")
        XCTAssertThrowsError(try table.consumeLocalToken(sessionID: 1, token: "wrong"))
    }

    func testDuplicateSessionIDRejected() throws {
        var table = SessionTable()
        try table.add(sessionID: 1, name: "u", guestToken: "g", localToken: "l")
        XCTAssertThrowsError(
            try table.add(sessionID: 1, name: "u", guestToken: "g2", localToken: "l2"))
    }

    func testLiveCountAndPerNameCounts() throws {
        var table = SessionTable()
        try table.add(sessionID: 1, name: "ubuntu", guestToken: "g", localToken: "l")
        try table.add(sessionID: 2, name: "ubuntu", guestToken: "g", localToken: "l")
        try table.add(sessionID: 3, name: "debian", guestToken: "g", localToken: "l")
        XCTAssertEqual(table.liveCount, 3)
        XCTAssertEqual(table.sessions(forName: "ubuntu"), 2)
        XCTAssertEqual(table.sessions(forName: "debian"), 1)
        XCTAssertTrue(table.remove(sessionID: 2))
        XCTAssertEqual(table.sessions(forName: "ubuntu"), 1)
        XCTAssertEqual(table.liveCount, 2)
        XCTAssertFalse(table.remove(sessionID: 2))
    }

    func testNameLookup() throws {
        var table = SessionTable()
        try table.add(sessionID: 1, name: "ubuntu", guestToken: "g", localToken: "l")
        XCTAssertEqual(table.name(of: 1), "ubuntu")
        XCTAssertNil(table.name(of: 2))
    }
}

final class SessionTableOrphanTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func table(openedAgo: TimeInterval, now: Date) throws -> SessionTable {
        var table = SessionTable()
        try table.add(
            sessionID: 1, name: "ubuntu", guestToken: "g", localToken: "l",
            openedAt: now.addingTimeInterval(-openedAgo))
        return table
    }

    func testPendingSessionExpiresPastDeadline() throws {
        let now = epoch
        let table = try self.table(openedAgo: 31, now: now)
        XCTAssertEqual(table.expiredPending(now: now, deadline: 30), [1])
        XCTAssertEqual(table.liveCountForIdle(now: now, deadline: 30), 0)
    }

    func testPendingSessionWithinDeadlineIsLive() throws {
        let now = epoch
        let table = try self.table(openedAgo: 10, now: now)
        XCTAssertTrue(table.expiredPending(now: now, deadline: 30).isEmpty)
        XCTAssertEqual(table.liveCountForIdle(now: now, deadline: 30), 1)
    }

    func testAttachedSessionNeverExpires() throws {
        let now = epoch
        var table = try self.table(openedAgo: 999, now: now)
        _ = try table.consumeLocalToken(sessionID: 1, token: "l")
        XCTAssertTrue(table.expiredPending(now: now, deadline: 30).isEmpty)
        XCTAssertEqual(table.liveCountForIdle(now: now, deadline: 30), 1)
    }

    func testReapedAttachFailureDropsLiveCountToZero() throws {
        let now = epoch
        var table = try self.table(openedAgo: 0, now: now)
        _ = try table.consumeLocalToken(sessionID: 1, token: "l")  // token consumed
        XCTAssertEqual(table.liveCountForIdle(now: now, deadline: 30), 1)
        XCTAssertTrue(table.remove(sessionID: 1))  // reap after DataPlane failure
        XCTAssertEqual(table.liveCountForIdle(now: now, deadline: 30), 0)
        XCTAssertEqual(table.liveCount, 0)
    }
}

final class TokenTests: XCTestCase {
    func testGenerateIsThirtyTwoHexChars() {
        let token = Token.generate()
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
    }

    func testGenerateIsUnique() {
        XCTAssertNotEqual(Token.generate(), Token.generate())
    }

    func testMatches() {
        XCTAssertTrue(Token.matches("abcd", "abcd"))
        XCTAssertFalse(Token.matches("abcd", "abce"))
        XCTAssertFalse(Token.matches("abcd", "abcde"))
    }
}
