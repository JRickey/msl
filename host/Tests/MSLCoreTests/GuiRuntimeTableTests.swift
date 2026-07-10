import Foundation
import XCTest

@testable import MSLCore

final class GuiRuntimeTableTests: XCTestCase {
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

    func testKeyNormalizesDefaultUser() {
        let anonymous = GuiRuntimeTable.Key(distro: "ubuntu", user: nil)
        XCTAssertNil(anonymous.requestedUser)
        XCTAssertEqual(anonymous.label, "ubuntu/default")
        XCTAssertEqual(key.requestedUser, "devuser")
        XCTAssertEqual(key.label, "ubuntu/devuser")
    }

    // MARK: - Token contract

    func testMintRefusedWithoutPreparedRuntime() {
        var table = GuiRuntimeTable()
        XCTAssertThrowsError(
            try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now))
    }

    func testAttachRefusedWithoutPreparedRuntime() {
        var table = GuiRuntimeTable()
        XCTAssertThrowsError(try table.consume(key: key, token: token, now: now))
    }

    func testAttachRefusedWhenRuntimeFailed() throws {
        var table = GuiRuntimeTable()
        try table.prepare(
            key: key, runtime: runtime(state: "failed"), graceUntil: now.addingTimeInterval(60))
        XCTAssertThrowsError(
            try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now))
        XCTAssertThrowsError(try table.consume(key: key, token: token, now: now))
    }

    func testTokenIsSingleUse() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        XCTAssertNoThrow(try table.consume(key: key, token: token, now: now))
        XCTAssertThrowsError(try table.consume(key: key, token: token, now: now))
    }

    func testTokenExpires() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        XCTAssertThrowsError(
            try table.consume(key: key, token: token, now: now.addingTimeInterval(31)))
    }

    func testTokenIsBoundToRuntimeIdentity() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        let other = GuiRuntimeTable.Key(distro: "ubuntu", user: nil)
        XCTAssertThrowsError(try table.consume(key: other, token: token, now: now))
    }

    func testWrongTokenIsRejected() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        XCTAssertThrowsError(
            try table.consume(key: key, token: String(repeating: "b", count: 32), now: now))
    }

    func testPendingTokensAreBounded() throws {
        var table = try prepared()
        for index in 0..<GuiRuntimeTable.maxTokens {  // bounded: token cap
            try table.mint(
                key: key, token: "token-\(index)", expires: now.addingTimeInterval(30), now: now)
        }
        let expires = now.addingTimeInterval(30)
        XCTAssertThrowsError(try table.mint(key: key, token: "over", expires: expires, now: now))
    }

    func testRuntimesAreBounded() throws {
        var table = GuiRuntimeTable()
        for index in 0..<GuiRuntimeTable.maxRuntimes {  // bounded: runtime cap
            try table.prepare(
                key: GuiRuntimeTable.Key(distro: "d\(index)", user: nil), runtime: runtime(),
                graceUntil: now)
        }
        XCTAssertEqual(table.count, GuiRuntimeTable.maxRuntimes)
        XCTAssertThrowsError(
            try table.prepare(
                key: GuiRuntimeTable.Key(distro: "extra", user: nil), runtime: runtime(),
                graceUntil: now))
    }

    func testPresentersAreBounded() throws {
        var table = try prepared()
        for index in 0...GuiRuntimeTable.maxPresenters {  // bounded: presenter cap + 1
            let value = "token-\(index)"
            try table.mint(key: key, token: value, expires: now.addingTimeInterval(30), now: now)
            if index < GuiRuntimeTable.maxPresenters {
                XCTAssertNoThrow(try table.consume(key: key, token: value, now: now))
            } else {
                XCTAssertThrowsError(try table.consume(key: key, token: value, now: now))
            }
        }
    }

    // MARK: - Idle holds

    func testLiveAppHoldsTheVM() throws {
        var table = try prepared()
        table.addWindow(key: key)
        let past = now.addingTimeInterval(3600)
        XCTAssertEqual(table.holdCount(now: past), 1)
        XCTAssertFalse(
            IdlePolicy.shouldStop(
                now: past, lastActivity: now, liveSessions: 0, pendingOps: 0,
                guiHolds: table.holdCount(now: past), timeoutSeconds: 60))
    }

    func testConnectedPresenterHoldsTheVM() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        try table.consume(key: key, token: token, now: now)
        let past = now.addingTimeInterval(3600)
        XCTAssertEqual(table.holdCount(now: past), 1)
        XCTAssertFalse(
            IdlePolicy.shouldStop(
                now: past, lastActivity: now, liveSessions: 0, pendingOps: 0,
                guiHolds: table.holdCount(now: past), timeoutSeconds: 60))
    }

    func testPresenterDisconnectOpensBoundedReconnectWindow() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        try table.consume(key: key, token: token, now: now)
        table.presenterFinished(key: key, graceUntil: now.addingTimeInterval(60))
        XCTAssertEqual(table.holdCount(now: now.addingTimeInterval(30)), 1)
        XCTAssertTrue(table.expired(now: now.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(table.expired(now: now.addingTimeInterval(61)), [key])
    }

    func testPresenterlessRuntimeIsNotExpiredWhileGraceIsOpen() throws {
        let table = try prepared()
        XCTAssertTrue(table.expired(now: now.addingTimeInterval(59)).isEmpty)
        XCTAssertEqual(table.expired(now: now.addingTimeInterval(60)), [key])
    }

    func testEmptyTableHoldsNothing() {
        XCTAssertEqual(GuiRuntimeTable().holdCount(now: now), 0)
        XCTAssertTrue(
            IdlePolicy.shouldStop(
                now: now.addingTimeInterval(60), lastActivity: now, liveSessions: 0, pendingOps: 0,
                guiHolds: 0, timeoutSeconds: 60))
    }

    // MARK: - Teardown

    func testRemoveClearsHoldsTokensAndPresenters() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        try table.consume(key: key, token: token, now: now)
        table.addWindow(key: key)
        XCTAssertTrue(table.remove(key: key))
        XCTAssertEqual(table.count, 0)
        XCTAssertEqual(table.holdCount(now: now), 0)
        XCTAssertThrowsError(try table.consume(key: key, token: token, now: now))
        XCTAssertFalse(table.remove(key: key))
    }

    func testRemoveAllClearsEveryRuntime() throws {
        var table = try prepared()
        try table.prepare(
            key: GuiRuntimeTable.Key(distro: "fedora", user: nil), runtime: runtime(),
            graceUntil: now.addingTimeInterval(60))
        table.removeAll()
        XCTAssertEqual(table.count, 0)
        XCTAssertEqual(table.holdCount(now: now), 0)
        XCTAssertTrue(table.keys(distro: nil).isEmpty)
    }

    func testKeysFilterByDistro() throws {
        var table = try prepared()
        try table.prepare(
            key: GuiRuntimeTable.Key(distro: "fedora", user: nil), runtime: runtime(),
            graceUntil: now)
        XCTAssertEqual(table.keys(distro: "ubuntu"), [key])
        XCTAssertEqual(table.keys(distro: nil).count, 2)
    }

    func testPresenterFinishedOnUnknownKeyIsANoOp() {
        var table = GuiRuntimeTable()
        table.presenterFinished(key: key, graceUntil: now)
        table.addWindow(key: key)
        XCTAssertEqual(table.count, 0)
    }

    // MARK: - Status

    func testStatusesReportPresentersAndWindows() throws {
        var table = try prepared()
        try table.mint(key: key, token: token, expires: now.addingTimeInterval(30), now: now)
        try table.consume(key: key, token: token, now: now)
        table.addWindow(key: key)
        table.addWindow(key: key)
        let statuses = table.statuses()
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].distro, "ubuntu")
        XCTAssertEqual(statuses[0].user, "devuser")
        XCTAssertEqual(statuses[0].state, "running")
        XCTAssertEqual(statuses[0].pid, 1234)
        XCTAssertEqual(statuses[0].waylandDisplay, "msl-way-0")
        XCTAssertEqual(statuses[0].presenters, 1)
        XCTAssertEqual(statuses[0].windows, 2)
    }

    func testFailRecordsLastError() throws {
        var table = try prepared()
        table.fail(key: key, error: "msl-way exited")
        XCTAssertEqual(table.statuses()[0].state, "failed")
        XCTAssertEqual(table.statuses()[0].lastError, "msl-way exited")
    }

    func testStatusDataSurvivesRoundTrip() throws {
        let gui = GuiRuntimeStatus(
            distro: "ubuntu", user: "devuser", state: "running", pid: 1234,
            waylandDisplay: "msl-way-0", x11Display: ":42", presenters: 1, windows: 3,
            lastError: nil)
        let status = StatusData(
            vm: "running", distros: [DistroStatus(name: "ubuntu", state: "running", sessions: 0)],
            idleTimeoutS: 60, gui: [gui])
        let decoded = try JSONDecoder().decode(
            StatusData.self, from: try JSONEncoder().encode(status))
        XCTAssertEqual(decoded, status)
        XCTAssertEqual(decoded.gui?.first?.presenters, 1)
        XCTAssertEqual(decoded.gui?.first?.windows, 3)
        XCTAssertEqual(decoded.gui?.first?.x11Display, ":42")
    }

    func testStatusDataWithoutGuiDecodes() throws {
        let frame = Data("{\"vm\":\"running\",\"distros\":[],\"idle_timeout_s\":60}".utf8)
        let decoded = try JSONDecoder().decode(StatusData.self, from: frame)
        XCTAssertNil(decoded.gui)
    }

    func testGuiTokenDataRoundTrip() throws {
        let minted = GuiTokenData(distro: "ubuntu", user: "devuser", token: token, expiresInS: 30)
        let decoded = try JSONDecoder().decode(
            GuiTokenData.self, from: try JSONEncoder().encode(minted))
        XCTAssertEqual(decoded, minted)
        XCTAssertEqual(decoded.expiresInS, 30)
    }
}
