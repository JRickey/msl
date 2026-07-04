import AppKit
import Foundation

// Toplevel-only resize hooks and size limits. Popups are client-sized and never
// reach these paths (they carry no NSWindowDelegate and are not resizable).
extension GuiWindow {
    func windowWillStartLiveResize(_ notification: Notification) {
        sizeState = .liveResize
        // Anchor stale content at native size during the drag (compositor
        // practice): scaling it blurs; the exposed strip stays blank instead.
        if let layer = view.layer {
            layer.contentsGravity = layer.contentsAreFlipped() ? .bottomLeft : .topLeft
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !remoteApplying else { return }
        resizePending = boundsPoints()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        sizeState = .settled
        resizePending = boundsPoints()
        view.layer?.contentsGravity = .resizeAspect
    }

    /// Apply the client's min/max size hints (0 = unconstrained). The min is
    /// clamped to the screen's usable content size; AppKit then stops a shrink
    /// drag at the floor, so a below-minimum size never reaches the client.
    func applyLimits(_ limits: GuiWinLimits) {
        let maxW = limits.maxWidth
        let maxH = limits.maxHeight
        let badMax =
            (maxW != 0 && maxW < limits.minWidth) || (maxH != 0 && maxH < limits.minHeight)
        if badMax { logBadLimitsOnce(limits) }
        if limits.minWidth == 0, limits.minHeight == 0 {
            window.contentMinSize = .zero
        } else {
            let raw = GuiSizePoints(
                width: Double(limits.minWidth), height: Double(limits.minHeight))
            let clamped = GuiWindow.clamp(raw, to: window.screen ?? NSScreen.main)
            window.contentMinSize = NSSize(width: clamped.width, height: clamped.height)
        }
        let unbounded = CGFloat.greatestFiniteMagnitude
        window.contentMaxSize = NSSize(
            width: (maxW == 0 || badMax) ? unbounded : CGFloat(maxW),
            height: (maxH == 0 || badMax) ? unbounded : CGFloat(maxH))
        assert(window.contentMinSize.width <= window.contentMaxSize.width, "min beyond max")
        assert(window.contentMinSize.height <= window.contentMaxSize.height, "min beyond max")
    }
}
