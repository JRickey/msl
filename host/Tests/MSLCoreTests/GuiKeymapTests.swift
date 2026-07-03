import XCTest

@testable import MSLCore

final class GuiKeymapTests: XCTestCase {
    func testKnownKeysMap() {
        XCTAssertEqual(GuiKeymap.evdev(for: 0x00), 30)  // A → KEY_A
        XCTAssertEqual(GuiKeymap.evdev(for: 0x24), 28)  // Return → KEY_ENTER
        XCTAssertEqual(GuiKeymap.evdev(for: 0x31), 57)  // Space → KEY_SPACE
        XCTAssertEqual(GuiKeymap.evdev(for: 0x35), 1)  // Escape → KEY_ESC
        XCTAssertEqual(GuiKeymap.evdev(for: 0x7E), 103)  // Up → KEY_UP
        XCTAssertEqual(GuiKeymap.evdev(for: 0x38), 42)  // Shift → KEY_LEFTSHIFT
    }

    func testUnknownKeyReturnsReserved() {
        XCTAssertEqual(GuiKeymap.evdev(for: 0xFFFF), GuiKeymap.keyReserved)
        XCTAssertEqual(GuiKeymap.evdev(for: 0x99), GuiKeymap.keyReserved)
    }

    func testTotalOverEveryVirtualCode() {
        for code in UInt16(0)...UInt16(1023) {  // bounded: fixed virtual-code sweep
            _ = GuiKeymap.evdev(for: code)
        }
    }

    func testTableHasNoDuplicateEvdevCodes() {
        let values = Array(GuiKeymap.table.values)
        XCTAssertEqual(
            values.count, Set(values).count, "each virtual key maps to a distinct evdev code")
    }
}
