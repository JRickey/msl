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

    func testPunctuationRowMaps() {
        XCTAssertEqual(GuiKeymap.evdev(for: 0x1B), 12)  // - → KEY_MINUS
        XCTAssertEqual(GuiKeymap.evdev(for: 0x18), 13)  // = → KEY_EQUAL
        XCTAssertEqual(GuiKeymap.evdev(for: 0x2F), 52)  // . → KEY_DOT
        XCTAssertEqual(GuiKeymap.evdev(for: 0x2C), 53)  // / → KEY_SLASH
        XCTAssertEqual(GuiKeymap.evdev(for: 0x29), 39)  // ; → KEY_SEMICOLON
        XCTAssertEqual(GuiKeymap.evdev(for: 0x27), 40)  // ' → KEY_APOSTROPHE
        XCTAssertEqual(GuiKeymap.evdev(for: 0x32), 41)  // ` → KEY_GRAVE
        XCTAssertEqual(GuiKeymap.evdev(for: 0x2A), 43)  // backslash → KEY_BACKSLASH
        XCTAssertEqual(GuiKeymap.evdev(for: 0x21), 26)  // [ → KEY_LEFTBRACE
        XCTAssertEqual(GuiKeymap.evdev(for: 0x1E), 27)  // ] → KEY_RIGHTBRACE
        XCTAssertEqual(GuiKeymap.evdev(for: 0x2B), 51)  // , → KEY_COMMA
    }

    func testFunctionAndNavClusterMaps() {
        XCTAssertEqual(GuiKeymap.evdev(for: 0x7A), 59)  // F1 → KEY_F1
        XCTAssertEqual(GuiKeymap.evdev(for: 0x6F), 88)  // F12 → KEY_F12
        XCTAssertEqual(GuiKeymap.evdev(for: 0x73), 102)  // Home → KEY_HOME
        XCTAssertEqual(GuiKeymap.evdev(for: 0x77), 107)  // End → KEY_END
        XCTAssertEqual(GuiKeymap.evdev(for: 0x74), 104)  // PgUp → KEY_PAGEUP
        XCTAssertEqual(GuiKeymap.evdev(for: 0x79), 109)  // PgDn → KEY_PAGEDOWN
        XCTAssertEqual(GuiKeymap.evdev(for: 0x75), 111)  // Fwd Delete → KEY_DELETE
    }

    func testKeypadAndLocksMap() {
        XCTAssertEqual(GuiKeymap.evdev(for: GuiKeymap.virtualCapsLock), 58)  // KEY_CAPSLOCK
        XCTAssertEqual(GuiKeymap.evdev(for: 0x4C), 96)  // KP Enter → KEY_KPENTER
        XCTAssertEqual(GuiKeymap.evdev(for: 0x52), 82)  // KP 0 → KEY_KP0
        XCTAssertEqual(GuiKeymap.evdev(for: 0x5C), 73)  // KP 9 → KEY_KP9
        XCTAssertEqual(GuiKeymap.evdev(for: 0x43), 55)  // KP * → KEY_KPASTERISK
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
