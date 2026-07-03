import Foundation
import XCTest

@testable import MSLCore

final class IdlePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func idle(seconds: Double) -> Date {
        return now.addingTimeInterval(-seconds)
    }

    func testDisabledWhenTimeoutZero() {
        XCTAssertFalse(
            IdlePolicy.shouldStop(
                now: now, lastActivity: idle(seconds: 999), liveSessions: 0, pendingOps: 0,
                timeoutSeconds: 0))
    }

    func testBlockedByLiveSessions() {
        XCTAssertFalse(
            IdlePolicy.shouldStop(
                now: now, lastActivity: idle(seconds: 999), liveSessions: 1, pendingOps: 0,
                timeoutSeconds: 60))
    }

    func testBlockedByPendingOps() {
        XCTAssertFalse(
            IdlePolicy.shouldStop(
                now: now, lastActivity: idle(seconds: 999), liveSessions: 0, pendingOps: 1,
                timeoutSeconds: 60))
    }

    func testNotYetElapsed() {
        XCTAssertFalse(
            IdlePolicy.shouldStop(
                now: now, lastActivity: idle(seconds: 59), liveSessions: 0, pendingOps: 0,
                timeoutSeconds: 60))
    }

    func testStopsWhenIdlePastTimeout() {
        XCTAssertTrue(
            IdlePolicy.shouldStop(
                now: now, lastActivity: idle(seconds: 60), liveSessions: 0, pendingOps: 0,
                timeoutSeconds: 60))
        XCTAssertTrue(
            IdlePolicy.shouldStop(
                now: now, lastActivity: idle(seconds: 120), liveSessions: 0, pendingOps: 0,
                timeoutSeconds: 60))
    }
}
