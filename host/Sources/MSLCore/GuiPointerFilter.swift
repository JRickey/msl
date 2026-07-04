/// Occlusion routing for the tracking-area pointer stream (motion, crossing,
/// scroll). AppKit tracking rects don't occlude: a popup floating over its
/// parent leaves the cursor inside both views' rects, so both surfaces stream
/// motion for one physical position and the client's hover/grab state scrambles.
/// The rule: a surface only speaks for the cursor while it is the topmost msl
/// window under it; when another of our windows covers the point it goes silent
/// after one synthesized leave, so the guest surface never keeps stale focus.
public enum GuiPointerFilter {
    public enum Decision: Sendable, Equatable {
        case forward
        case suppress
        case leaveOnce
    }

    /// Decide a tracking event's fate. `topmostIsOurs` is whether the frontmost
    /// window at the cursor (across all apps) is one of ours; when it is and it
    /// is not this view's window, the view is occluded. `hasEntered` gates the
    /// one-shot leave: only a surface the guest still thinks is entered needs it.
    public static func decide(
        topmostWindowNumber: Int, selfWindowNumber: Int, topmostIsOurs: Bool, hasEntered: Bool
    ) -> Decision {
        assert(!(topmostIsOurs && topmostWindowNumber == 0), "an owned window number is never 0")
        guard topmostIsOurs, topmostWindowNumber != selfWindowNumber else { return .forward }
        assert(topmostWindowNumber != selfWindowNumber, "occlusion is by a different window")
        return hasEntered ? .leaveOnce : .suppress
    }
}
