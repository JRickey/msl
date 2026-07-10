import AppKit
import Foundation
import MSLCore

// GuiWindow diagnostics and static sizing helpers (split for file length).

extension GuiWindow {
    func logPartialResizeOnce() {
        guard !loggedPartialResize else { return }
        loggedPartialResize = true
        warn("resize commit did not fully damage the new buffer")
    }

    func logBadLimitsOnce(_ limits: GuiWinLimits) {
        guard !loggedBadLimits else { return }
        loggedBadLimits = true
        warn("client max size below min (\(limits.maxWidth)x\(limits.maxHeight))")
    }

    func logSerialBugOnce(_ serial: UInt32) {
        guard !loggedSerialBug else { return }
        loggedSerialBug = true
        warn("commit serial \(serial) exceeds sent \(sentSerial)")
    }

    private func warn(_ message: String) {
        assert(!message.isEmpty, "diagnostic message is non-empty")
        let line = "gui-spike win \(win): \(message)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    static let styleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable,
    ]

    /// Largest content size whose full frame — title bar included — fits the
    /// screen's visible area; clamping to the raw visibleFrame leaves a frame
    /// AppKit must constrain, which shoves the window under the menu bar.
    static func clamp(_ points: GuiSizePoints, to screen: NSScreen?) -> GuiSizePoints {
        guard let visible = screen?.visibleFrame else { return points }
        let usable = NSWindow.contentRect(forFrameRect: visible, styleMask: styleMask).size
        assert(usable.width <= visible.width, "content fits inside the frame")
        assert(usable.height <= visible.height, "content fits inside the frame")
        let width = min(points.width, Double(usable.width))
        let height = min(points.height, Double(usable.height))
        return GuiSizePoints(width: max(1, width), height: max(1, height))
    }

    static func cursor(for name: String) -> NSCursor {
        switch name {
        case "text": return .iBeam
        case "pointer": return .pointingHand
        case "grab": return .openHand
        default: return .arrow
        }
    }
}
