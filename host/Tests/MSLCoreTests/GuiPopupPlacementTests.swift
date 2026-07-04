import CoreGraphics
import XCTest

@testable import MSLCore

private func size(_ width: Double, _ height: Double) -> GuiSizePoints {
    return GuiSizePoints(width: width, height: height)
}

/// Derive a placed window's content top-left (screen coords) the way a nested
/// popup anchors to its parent: minX and the top (maxY) of the placed frame.
private func topLeft(of frame: CGRect) -> CGPoint {
    return CGPoint(x: frame.minX, y: frame.maxY)
}

final class GuiPopupPlacementTests: XCTestCase {
    private let bigScreen = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    func testAnchorConversionNoSlide() {
        let rect = GuiPopupPlacement.place(
            parentContentTopLeft: CGPoint(x: 100, y: 500), offsetX: 10, offsetY: 20,
            size: size(50, 40), visibleFrame: bigScreen)
        XCTAssertEqual(rect.minX, 110, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 440, accuracy: 0.001, "y = parentTopY - offY - height")
        XCTAssertEqual(rect.width, 50, accuracy: 0.001)
        XCTAssertEqual(rect.height, 40, accuracy: 0.001)
    }

    func testSlidesLeftToFitRightEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let rect = GuiPopupPlacement.place(
            parentContentTopLeft: CGPoint(x: 980, y: 500), offsetX: 10, offsetY: 0,
            size: size(100, 40), visibleFrame: screen)
        XCTAssertEqual(rect.minX, 900, accuracy: 0.001, "right overflow slides left to maxX")
        XCTAssertEqual(rect.origin.y, 460, accuracy: 0.001, "y axis is untouched by an x slide")
    }

    func testSlidesUpIndependentlyOfX() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let rect = GuiPopupPlacement.place(
            parentContentTopLeft: CGPoint(x: 100, y: 30), offsetX: 0, offsetY: 0,
            size: size(50, 40), visibleFrame: screen)
        XCTAssertEqual(rect.minX, 100, accuracy: 0.001, "x within bounds stays put")
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.001, "bottom overflow slides up to minY")
    }

    func testOversizeSegmentPinsToLowerEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let rect = GuiPopupPlacement.place(
            parentContentTopLeft: CGPoint(x: 100, y: 500), offsetX: 0, offsetY: 0,
            size: size(1200, 40), visibleFrame: screen)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001, "a popup wider than the screen pins to minX")
    }

    func testNestedPopupAnchorsToSlidParent() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let parent = GuiPopupPlacement.place(
            parentContentTopLeft: CGPoint(x: 950, y: 500), offsetX: 60, offsetY: 0,
            size: size(100, 40), visibleFrame: screen)
        XCTAssertEqual(parent.minX, 900, accuracy: 0.001, "parent itself slid left")
        let child = GuiPopupPlacement.place(
            parentContentTopLeft: topLeft(of: parent), offsetX: 10, offsetY: 0,
            size: size(50, 30), visibleFrame: screen)
        XCTAssertEqual(child.minX, 910, accuracy: 0.001, "child compounds the parent's slide")
        XCTAssertEqual(child.origin.y, 470, accuracy: 0.001, "child anchors to parent top (500)")
    }

    func testSizeChangeKeepsTopFixedMovesBottom() {
        let small = GuiPopupPlacement.place(
            parentContentTopLeft: CGPoint(x: 100, y: 500), offsetX: 0, offsetY: 50,
            size: size(60, 40), visibleFrame: bigScreen)
        let large = GuiPopupPlacement.place(
            parentContentTopLeft: CGPoint(x: 100, y: 500), offsetX: 0, offsetY: 50,
            size: size(60, 80), visibleFrame: bigScreen)
        XCTAssertEqual(small.maxY, 450, accuracy: 0.001, "top edge is anchored")
        XCTAssertEqual(large.maxY, 450, accuracy: 0.001, "growth keeps the top edge fixed")
        XCTAssertLessThan(large.origin.y, small.origin.y, "growth moves the bottom edge down")
    }
}
