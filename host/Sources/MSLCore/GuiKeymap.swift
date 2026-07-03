import Foundation

/// Static macOS virtual-keycode → Linux evdev-keycode table for the spike
/// (ASCII, arrows, modifiers). `evdev(for:)` is total: an unmapped virtual key
/// returns `keyReserved` (0), which the caller drops rather than forwarding.
public enum GuiKeymap {
    public static let keyReserved: UInt32 = 0

    /// Translate one macOS virtual keycode to an evdev keycode, or `keyReserved`
    /// when the spike table has no entry (total function, no partiality).
    public static func evdev(for virtualCode: UInt16) -> UInt32 {
        assert(!GuiKeymap.table.isEmpty, "keymap table must be populated")
        let mapped = GuiKeymap.table[virtualCode] ?? keyReserved
        assert(mapped <= 255, "spike evdev codes stay within one byte")
        return mapped
    }

    /// macOS `kVK_*` (Carbon HIToolbox) → evdev `KEY_*`. Values are the stable
    /// virtual keycodes and evdev codes; both are fixed hardware-facing numbers.
    static let table: [UInt16: UInt32] = [
        0x00: 30,  // A → KEY_A
        0x0B: 48,  // B → KEY_B
        0x08: 46,  // C → KEY_C
        0x02: 32,  // D → KEY_D
        0x0E: 18,  // E → KEY_E
        0x03: 33,  // F → KEY_F
        0x05: 34,  // G → KEY_G
        0x04: 35,  // H → KEY_H
        0x22: 23,  // I → KEY_I
        0x26: 36,  // J → KEY_J
        0x28: 37,  // K → KEY_K
        0x25: 38,  // L → KEY_L
        0x2E: 50,  // M → KEY_M
        0x2D: 49,  // N → KEY_N
        0x1F: 24,  // O → KEY_O
        0x23: 25,  // P → KEY_P
        0x0C: 16,  // Q → KEY_Q
        0x0F: 19,  // R → KEY_R
        0x01: 31,  // S → KEY_S
        0x11: 20,  // T → KEY_T
        0x20: 22,  // U → KEY_U
        0x09: 47,  // V → KEY_V
        0x0D: 17,  // W → KEY_W
        0x07: 45,  // X → KEY_X
        0x10: 21,  // Y → KEY_Y
        0x06: 44,  // Z → KEY_Z
        0x12: 2,  // 1 → KEY_1
        0x13: 3,  // 2 → KEY_2
        0x14: 4,  // 3 → KEY_3
        0x15: 5,  // 4 → KEY_4
        0x17: 6,  // 5 → KEY_5
        0x16: 7,  // 6 → KEY_6
        0x1A: 8,  // 7 → KEY_7
        0x1C: 9,  // 8 → KEY_8
        0x19: 10,  // 9 → KEY_9
        0x1D: 11,  // 0 → KEY_0
        0x24: 28,  // Return → KEY_ENTER
        0x30: 15,  // Tab → KEY_TAB
        0x31: 57,  // Space → KEY_SPACE
        0x33: 14,  // Delete → KEY_BACKSPACE
        0x35: 1,  // Escape → KEY_ESC
        0x7B: 105,  // Left → KEY_LEFT
        0x7C: 106,  // Right → KEY_RIGHT
        0x7D: 108,  // Down → KEY_DOWN
        0x7E: 103,  // Up → KEY_UP
        0x38: 42,  // Shift → KEY_LEFTSHIFT
        0x3C: 54,  // Right Shift → KEY_RIGHTSHIFT
        0x3B: 29,  // Control → KEY_LEFTCTRL
        0x3E: 97,  // Right Control → KEY_RIGHTCTRL
        0x3A: 56,  // Option → KEY_LEFTALT
        0x3D: 100,  // Right Option → KEY_RIGHTALT
        0x37: 125,  // Command → KEY_LEFTMETA
        0x36: 126,  // Right Command → KEY_RIGHTMETA
    ]
}

/// evdev button codes for the pointer messages (host-native input mapping).
public enum GuiButton {
    public static let left: UInt32 = 0x110  // BTN_LEFT
    public static let right: UInt32 = 0x111  // BTN_RIGHT
    public static let middle: UInt32 = 0x112  // BTN_MIDDLE
}
