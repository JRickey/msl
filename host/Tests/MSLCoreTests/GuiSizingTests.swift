import XCTest

@testable import MSLCore

private func points(_ width: Double, _ height: Double) -> GuiSizePoints {
    return GuiSizePoints(width: width, height: height)
}

final class GuiSizingBufferPointsTests: XCTestCase {
    func testScaleOneIsIdentity() {
        let result = GuiSizing.bufferPoints(widthPx: 1280, heightPx: 800, scaleE12: 4096)
        XCTAssertEqual(result, points(1280, 800))
    }

    func testScaleTwoHalvesPoints() {
        let result = GuiSizing.bufferPoints(widthPx: 1280, heightPx: 800, scaleE12: 8192)
        XCTAssertEqual(result, points(640, 400))
    }

    func testFractionalScale() {
        let result = GuiSizing.bufferPoints(widthPx: 1500, heightPx: 1000, scaleE12: 6144)
        XCTAssertEqual(result.width, 1000, accuracy: 0.001)
        XCTAssertEqual(result.height, 666.6667, accuracy: 0.001)
    }
}

/// Table over the protocol "Size authority" state machine: each case names the
/// transition it proves. sent = newest serial the host sent.
final class GuiSizingVerdictTests: XCTestCase {
    private func verdict(
        _ state: GuiSizeState, sent: UInt32, commit: UInt32,
        buffer: GuiSizePoints, content: GuiSizePoints
    ) -> GuiSizeVerdict {
        return GuiSizing.verdict(
            state: state, sentSerial: sent, commitSerial: commit,
            bufferPoints: buffer, contentPoints: content)
    }

    func testInitialMapAlwaysPixelsOnly() {
        let result = verdict(
            .initialMap, sent: 0, commit: 0, buffer: points(800, 600), content: points(400, 300))
        XCTAssertEqual(result, .pixelsOnly)
    }

    func testLiveResizeCurrentDifferStaysPixelsOnly() {
        let result = verdict(
            .liveResize, sent: 4, commit: 4, buffer: points(900, 700), content: points(800, 600))
        XCTAssertEqual(result, .pixelsOnly)
    }

    func testLiveResizeStaleStaysPixelsOnly() {
        let result = verdict(
            .liveResize, sent: 4, commit: 2, buffer: points(900, 700), content: points(800, 600))
        XCTAssertEqual(result, .pixelsOnly)
    }

    func testSettledStalePixelsOnlyEvenWhenPointsDiffer() {
        let result = verdict(
            .settled, sent: 5, commit: 3, buffer: points(1000, 800), content: points(640, 480))
        XCTAssertEqual(result, .pixelsOnly, "stale commit never re-grows geometry")
    }

    func testSettledCurrentEqualPixelsOnly() {
        let result = verdict(
            .settled, sent: 5, commit: 5, buffer: points(640, 480), content: points(640, 480))
        XCTAssertEqual(result, .pixelsOnly)
    }

    func testSettledCurrentDifferAppliesGeometry() {
        let result = verdict(
            .settled, sent: 5, commit: 5, buffer: points(700, 500), content: points(640, 480))
        XCTAssertEqual(result, .applyGeometry(points(700, 500)))
    }

    func testSerialZeroBeforeFirstConfigureEqualPixelsOnly() {
        let result = verdict(
            .settled, sent: 0, commit: 0, buffer: points(800, 600), content: points(800, 600))
        XCTAssertEqual(result, .pixelsOnly)
    }

    func testSerialZeroBeforeFirstConfigureDifferAppliesGeometry() {
        let result = verdict(
            .settled, sent: 0, commit: 0, buffer: points(820, 600), content: points(800, 600))
        XCTAssertEqual(
            result, .applyGeometry(points(820, 600)), "client self-resize before any configure")
    }

    func testSerialZeroAfterFirstConfigureIsStale() {
        let result = verdict(
            .settled, sent: 1, commit: 0, buffer: points(700, 500), content: points(640, 480))
        XCTAssertEqual(result, .pixelsOnly, "clamped-initial-map echoes carry serial 0 < 1")
    }

    func testSerialAboveSentFlagsStaleFuture() {
        let result = verdict(
            .settled, sent: 3, commit: 4, buffer: points(700, 500), content: points(640, 480))
        XCTAssertEqual(result, .pixelsOnlyStaleFuture)
    }

    func testSerialAboveSentDuringLiveResizeFlagsStaleFuture() {
        let result = verdict(
            .liveResize, sent: 3, commit: 4, buffer: points(700, 500), content: points(640, 480))
        XCTAssertEqual(result, .pixelsOnlyStaleFuture)
    }

    func testSubHalfPointDifferenceIsPixelsOnly() {
        let result = verdict(
            .settled, sent: 2, commit: 2, buffer: points(640.4, 480.4), content: points(640, 480))
        XCTAssertEqual(result, .pixelsOnly, "rounding noise below half a point is not a resize")
    }

    func testHalfPointDifferenceAppliesGeometry() {
        let result = verdict(
            .settled, sent: 2, commit: 2, buffer: points(640.5, 480), content: points(640, 480))
        XCTAssertEqual(result, .applyGeometry(points(640.5, 480)))
    }

    func testRepeatedAppliedPairIsPixelsOnly() {
        let last = GuiAppliedGeometry(serial: 5, points: points(700, 500))
        let result = GuiSizing.verdict(
            state: .settled, sentSerial: 5, commitSerial: 5,
            bufferPoints: points(700, 500), contentPoints: points(640, 480), lastApplied: last)
        XCTAssertEqual(
            result, .pixelsOnly, "a (serial, points) pair applies once even if content lags")
    }

    func testNewPointsAtAppliedSerialStillApplies() {
        let last = GuiAppliedGeometry(serial: 5, points: points(700, 500))
        let result = GuiSizing.verdict(
            state: .settled, sentSerial: 5, commitSerial: 5,
            bufferPoints: points(750, 520), contentPoints: points(640, 480), lastApplied: last)
        XCTAssertEqual(result, .applyGeometry(points(750, 520)))
    }

    func testAppliedPointsAtNewSerialStillApplies() {
        let last = GuiAppliedGeometry(serial: 5, points: points(700, 500))
        let result = GuiSizing.verdict(
            state: .settled, sentSerial: 6, commitSerial: 6,
            bufferPoints: points(700, 500), contentPoints: points(640, 480), lastApplied: last)
        XCTAssertEqual(result, .applyGeometry(points(700, 500)))
    }
}
