import CoreGraphics

/// Pure popup placement: turn a parent-relative anchor into an on-screen panel
/// frame. The load-bearing invariant is that a popup is only ever slid (per axis,
/// independently) to fit the visible frame — never resized, never flipped — so
/// its size stays exactly what the client committed and nested popups compound
/// their parents' slides instead of drifting.
public enum GuiPopupPlacement {
    /// Place a popup of `size` points at `(offsetX, offsetY)` logical points from
    /// the parent content view's top-left (y measured downward). The result is an
    /// AppKit bottom-left-origin frame slid to sit inside `visibleFrame`.
    public static func place(
        parentContentTopLeft: CGPoint, offsetX: Double, offsetY: Double,
        size: GuiSizePoints, visibleFrame: CGRect
    ) -> CGRect {
        assert(size.width >= 1 && size.height >= 1, "popup size is at least one point")
        assert(visibleFrame.width > 0 && visibleFrame.height > 0, "visible frame is non-empty")
        let originX = Double(parentContentTopLeft.x) + offsetX
        let originY = Double(parentContentTopLeft.y) - offsetY - size.height
        let slidX = slide(
            origin: originX, length: size.width,
            lower: Double(visibleFrame.minX), upper: Double(visibleFrame.maxX))
        let slidY = slide(
            origin: originY, length: size.height,
            lower: Double(visibleFrame.minY), upper: Double(visibleFrame.maxY))
        return CGRect(x: slidX, y: slidY, width: size.width, height: size.height)
    }

    /// Slide a segment so it fits `[lower, upper]`: pull it in from the far edge
    /// first, then pin to the near edge, so a segment larger than the span rests
    /// at `lower` rather than resizing.
    static func slide(origin: Double, length: Double, lower: Double, upper: Double) -> Double {
        assert(length >= 0, "segment length is non-negative")
        assert(upper >= lower, "slide bounds are ordered")
        var value = origin
        if value + length > upper { value = upper - length }
        if value < lower { value = lower }
        return value
    }
}
