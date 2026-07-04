import XCTest

@testable import MSLCore

final class GuiPacerTests: XCTestCase {
    func testIdleTickHoldsWithNoCommit() {
        var pacer = GuiPacer()
        XCTAssertEqual(pacer.tick(), .hold)
    }

    func testCommitThenTickPresentsThatSeq() {
        var pacer = GuiPacer()
        pacer.onCommit(seq: 5)
        XCTAssertTrue(pacer.hasPending)
        XCTAssertEqual(pacer.tick(), .present(5))
        XCTAssertFalse(pacer.hasPending)
    }

    func testAtMostOneUnackedPresent() {
        var pacer = GuiPacer()
        pacer.onCommit(seq: 1)
        XCTAssertEqual(pacer.tick(), .present(1))
        pacer.onCommit(seq: 2)
        XCTAssertEqual(pacer.tick(), .hold, "must not present while a prior present is un-acked")
        pacer.onAck()
        XCTAssertEqual(pacer.tick(), .present(2))
    }

    func testCommitsCoalesceToLatest() {
        var pacer = GuiPacer()
        pacer.onCommit(seq: 1)
        pacer.onCommit(seq: 2)
        pacer.onCommit(seq: 3)
        XCTAssertEqual(pacer.tick(), .present(3))
    }

    func testAckWithoutPendingHolds() {
        var pacer = GuiPacer()
        pacer.onCommit(seq: 1)
        XCTAssertEqual(pacer.tick(), .present(1))
        pacer.onAck()
        XCTAssertEqual(pacer.tick(), .hold)
    }
}

final class GuiLedgerTests: XCTestCase {
    private func commit(_ recv: UInt64, _ present: UInt64) -> GuiCommitSample {
        return GuiCommitSample(
            win: 1, seq: 1, tRecvNs: recv, tPresentNs: present, tClientCommitNs: 0, tSendNs: 0)
    }

    func testPercentileNearestRank() {
        let values: [UInt64] = [10, 20, 30, 40, 50]
        XCTAssertEqual(GuiLedger.percentile(values, 0.5), 30)
        XCTAssertEqual(GuiLedger.percentile(values, 0.95), 50)
        XCTAssertEqual(GuiLedger.percentile(values, 0.0), 10)
    }

    func testPercentileEmptyIsNil() {
        XCTAssertNil(GuiLedger.percentile([], 0.5))
    }

    func testCommitPercentilesUseDelta() {
        var ledger = GuiLedger()
        ledger.addCommit(commit(0, 10))
        ledger.addCommit(commit(0, 20))
        ledger.addCommit(commit(0, 30))
        XCTAssertEqual(ledger.commitToPresent(0.5), 20)
    }

    func testPresentBeforeRecvClampsToZero() {
        let sample = commit(100, 40)
        XCTAssertEqual(sample.commitToPresentNs, 0)
    }

    func testInputSampleDelta() {
        let sample = GuiInputSample(win: 1, kind: "motion", tInputNs: 5, tPresentNs: 25)
        XCTAssertEqual(sample.inputToPresentNs, 20)
    }

    func testRingStaysBounded() {
        var ledger = GuiLedger()
        for index in 0..<(GuiLedger.capacity + 10) {  // bounded: fixed overfill
            ledger.addCommit(commit(0, UInt64(index)))
        }
        XCTAssertEqual(ledger.commitCount, GuiLedger.capacity)
    }

    func testCsvHasHeaderAndRows() {
        var ledger = GuiLedger()
        ledger.addCommit(commit(0, 10))
        ledger.addInput(GuiInputSample(win: 1, kind: "key", tInputNs: 0, tPresentNs: 5))
        let lines = ledger.csv().split(separator: "\n")
        XCTAssertTrue(lines[0].hasPrefix("kind,"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("commit,") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("input,") })
    }
}

final class KeepLatestTests: XCTestCase {
    func testStartsEmpty() {
        let latch = KeepLatest<Int>()
        XCTAssertTrue(latch.isEmpty)
    }

    func testStoreThenTakeReturnsValueAndClears() {
        var latch = KeepLatest<Int>()
        latch.store(7)
        XCTAssertFalse(latch.isEmpty)
        XCTAssertEqual(latch.take(), 7)
        XCTAssertTrue(latch.isEmpty)
    }

    func testStoreReplacesOlderValue() {
        var latch = KeepLatest<Int>()
        latch.store(1)
        latch.store(2)
        latch.store(3)
        XCTAssertEqual(latch.take(), 3, "only the newest value survives")
        XCTAssertNil(latch.take())
    }

    func testTakeOnEmptyIsNil() {
        var latch = KeepLatest<Int>()
        XCTAssertNil(latch.take())
    }
}

final class GuiCommitRouterTests: XCTestCase {
    private func held(_ seq: UInt32) -> GuiHeldCommit {
        let commit = GuiCommit(
            win: 5, seq: seq, width: 4, height: 4, stride: 16, format: 1, scaleE12: 4096, serial: 0,
            rects: [], tClientCommitNs: 0, tSendNs: 0, pixels: Data())
        return GuiHeldCommit(commit: commit, recvNs: 0)
    }

    func testLatchKeepsLatestAcrossStores() {
        let latch = GuiCommitLatch()
        latch.store(held(1))
        latch.store(held(2))
        XCTAssertEqual(latch.take()?.commit.seq, 2)
        XCTAssertNil(latch.take())
    }

    func testRouterStoresIntoRegisteredLatch() {
        let router = GuiCommitRouter()
        let latch = GuiCommitLatch()
        router.register(win: 5, latch: latch)
        router.store(win: 5, held: held(9))
        XCTAssertEqual(latch.take()?.commit.seq, 9)
    }

    func testRouterDropsUnknownWindow() {
        let router = GuiCommitRouter()
        router.store(win: 99, held: held(1))  // no crash, silently dropped
    }

    func testRouterUnregisterStopsDelivery() {
        let router = GuiCommitRouter()
        let latch = GuiCommitLatch()
        router.register(win: 5, latch: latch)
        router.unregister(win: 5)
        router.store(win: 5, held: held(3))
        XCTAssertNil(latch.take())
    }

    func testStoreBeforeWindowDrainsAfterRegistration() {
        let router = GuiCommitRouter()
        let latch = GuiCommitLatch()
        // Reader registers the latch and deposits commits before the window is
        // built on main; the newest survives for the first display-tick drain.
        router.register(win: 5, latch: latch)
        router.store(win: 5, held: held(1))
        router.store(win: 5, held: held(2))
        XCTAssertEqual(latch.take()?.commit.seq, 2)
        XCTAssertNil(latch.take())
    }
}
