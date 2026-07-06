import XCTest

@testable import MSLCore

final class DesktopProbeTests: XCTestCase {
    func testDetectsFirstSupportedSession() {
        let result = DesktopProbe.detect(commands: ["startplasma-wayland", "gnome-session"])
        XCTAssertEqual(result.session?.name, "gnome")
        XCTAssertEqual(result.session?.command, "gnome-session")
        XCTAssertTrue(result.available)
    }

    func testUnavailableWhenNoSupportedCommandExists() {
        let result = DesktopProbe.detect(commands: ["openbox-session"])
        XCTAssertNil(result.session)
        XCTAssertFalse(result.available)
    }
}
