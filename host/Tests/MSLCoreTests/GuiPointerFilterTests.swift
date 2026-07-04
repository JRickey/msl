import XCTest

@testable import MSLCore

final class GuiPointerFilterTests: XCTestCase {
    private func decide(
        topmost: Int, selfNum: Int, ours: Bool, entered: Bool
    ) -> GuiPointerFilter.Decision {
        return GuiPointerFilter.decide(
            topmostWindowNumber: topmost, selfWindowNumber: selfNum,
            topmostIsOurs: ours, hasEntered: entered)
    }

    func testSelfIsTopmostForwards() {
        XCTAssertEqual(decide(topmost: 7, selfNum: 7, ours: true, entered: true), .forward)
        XCTAssertEqual(decide(topmost: 7, selfNum: 7, ours: true, entered: false), .forward)
    }

    func testOccludedWhileEnteredEmitsOneLeave() {
        XCTAssertEqual(decide(topmost: 9, selfNum: 7, ours: true, entered: true), .leaveOnce)
    }

    func testOccludedAfterLeaveStaysSilent() {
        XCTAssertEqual(decide(topmost: 9, selfNum: 7, ours: true, entered: false), .suppress)
    }

    func testForeignTopmostIsNotOverFiltered() {
        // Another app's window on top: AppKit would not deliver to us, and if it
        // does we must not synthesize a leave for it.
        XCTAssertEqual(decide(topmost: 42, selfNum: 7, ours: false, entered: true), .forward)
        XCTAssertEqual(decide(topmost: 42, selfNum: 7, ours: false, entered: false), .forward)
    }

    func testNoWindowAtPointForwards() {
        XCTAssertEqual(decide(topmost: 0, selfNum: 7, ours: false, entered: true), .forward)
    }
}
