import CoreGraphics
import IOSurface
import XCTest

@testable import MSLCore

@MainActor
final class GuiSurfaceCornerTests: XCTestCase {
    func testCornerColorSamplesBottomRightPixel() {
        guard let surface = GuiSurface(width: 4, height: 3) else {
            return XCTFail("surface allocates")
        }
        guard surface.ioSurface.lock(options: [], seed: nil) == 0 else {
            return XCTFail("surface locks for writing")
        }
        let stride = surface.ioSurface.bytesPerRow
        let offset = (3 - 1) * stride + (4 - 1) * 4
        let px = surface.ioSurface.baseAddress.advanced(by: offset)
            .assumingMemoryBound(to: UInt8.self)
        // BGRA byte order: B, G, R, A.
        px[0] = 10
        px[1] = 20
        px[2] = 30
        px[3] = 255
        XCTAssertEqual(surface.ioSurface.unlock(options: [], seed: nil), 0)
        guard let components = surface.cornerColor()?.components, components.count >= 3 else {
            return XCTFail("corner sample locks and yields rgb components")
        }
        XCTAssertEqual(Double(components[0]), 30.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(Double(components[1]), 20.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(Double(components[2]), 10.0 / 255, accuracy: 0.0001)
    }
}
