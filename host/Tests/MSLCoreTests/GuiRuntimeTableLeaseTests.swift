import Foundation
import XCTest

@testable import MSLCore

/// The presenter-starting lease state machine and launched-app accounting split
/// off `GuiRuntimeTableTests` to keep each class under the body-length ceiling.
final class GuiRuntimeTableLeaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let key = GuiRuntimeTable.Key(distro: "ubuntu", user: "devuser")
    private let token = String(repeating: "a", count: 32)

    private func runtime(state: String = "running") -> GuiRuntimeData {
        return GuiRuntimeData(
            state: state, runtimeDir: "/run/user/1000/msl-gui", waylandDisplay: "msl-way-0",
            socketPresent: true, pid: 1234, logTail: "")
    }

    private func prepared() throws -> GuiRuntimeTable {
        var table = GuiRuntimeTable()
        try table.prepare(key: key, runtime: runtime(), graceUntil: now.addingTimeInterval(60))
        return table
    }

    // MARK: - Presenter-starting lease

    func testConcurrentLaunchesSpawnPresenterOnce() throws {
        var table = try prepared()
        let deadline = now.addingTimeInterval(30)
        XCTAssertTrue(
            table.beginPresenterSpawn(key: key, token: token, deadline: deadline, now: now))
        XCTAssertFalse(
            table.beginPresenterSpawn(key: key, token: "second", deadline: deadline, now: now))
    }

    func testExpiredLeaseAllowsRespawn() throws {
        var table = try prepared()
        XCTAssertTrue(
            table.beginPresenterSpawn(
                key: key, token: token, deadline: now.addingTimeInterval(30), now: now))
        let later = now.addingTimeInterval(31)
        XCTAssertTrue(
            table.beginPresenterSpawn(
                key: key, token: "again", deadline: later.addingTimeInterval(30), now: later))
    }

    func testAttachReleasesLeaseAndAttachedBlocksRespawn() throws {
        var table = try prepared()
        XCTAssertTrue(
            table.beginPresenterSpawn(
                key: key, token: token, deadline: now.addingTimeInterval(30), now: now))
        try table.consume(key: key, token: token, now: now)
        XCTAssertFalse(
            table.beginPresenterSpawn(
                key: key, token: "x", deadline: now.addingTimeInterval(30), now: now))
        table.presenterFinished(key: key, graceUntil: now.addingTimeInterval(60))
        XCTAssertTrue(
            table.beginPresenterSpawn(
                key: key, token: "y", deadline: now.addingTimeInterval(30), now: now))
    }

    func testAbortedSpawnReleasesLease() throws {
        var table = try prepared()
        XCTAssertTrue(
            table.beginPresenterSpawn(
                key: key, token: token, deadline: now.addingTimeInterval(30), now: now))
        table.abortPresenterSpawn(key: key, token: token)
        XCTAssertTrue(
            table.beginPresenterSpawn(
                key: key, token: "retry", deadline: now.addingTimeInterval(30), now: now))
    }

    func testStartingLeaseHoldsVMUntilItsDeadline() throws {
        var table = GuiRuntimeTable()
        try table.prepare(key: key, runtime: runtime(), graceUntil: now)  // grace already closed
        XCTAssertEqual(table.holdCount(now: now.addingTimeInterval(1)), 0)
        XCTAssertTrue(
            table.beginPresenterSpawn(
                key: key, token: token, deadline: now.addingTimeInterval(30), now: now))
        XCTAssertEqual(table.holdCount(now: now.addingTimeInterval(1)), 1)
        XCTAssertEqual(table.holdCount(now: now.addingTimeInterval(31)), 0)
    }

    // MARK: - Launched-app accounting

    func testPresenterFinishDrainsLaunchedProcesses() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        try table.consume(key: key, token: token, now: now)
        table.noteLaunchedProcess(key: key)
        table.noteLaunchedProcess(key: key)
        XCTAssertEqual(table.statuses()[0].windows, 2)
        table.presenterFinished(key: key, graceUntil: now.addingTimeInterval(60))
        XCTAssertEqual(table.statuses()[0].windows, 0)
    }

    func testGuiSessionIsIdleAfterGrace() throws {
        var table = try prepared()
        table.noteLaunchedProcess(key: key)
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        try table.consume(key: key, token: token, now: now)
        table.presenterFinished(key: key, graceUntil: now.addingTimeInterval(60))
        // Regression for the window-count leak: after the app's presenter exits and
        // the grace window closes, nothing holds the VM.
        XCTAssertEqual(table.holdCount(now: now.addingTimeInterval(61)), 0)
        XCTAssertTrue(
            IdlePolicy.shouldStop(
                now: now.addingTimeInterval(3600), lastActivity: now, liveSessions: 0,
                pendingOps: 0, guiHolds: table.holdCount(now: now.addingTimeInterval(3600)),
                timeoutSeconds: 60))
    }
}
