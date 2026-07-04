import AppKit
import Foundation

/// Whether a `GuiWindow` backs a remote toplevel or an xdg_popup. Popups skip the
/// size-authority machine: they are client-sized and placed against their parent.
enum GuiRole: Equatable {
    case toplevel
    case popup
}

// Popup panel behavior for GuiWindow: parent attachment, client-driven sizing,
// and anchored placement. All main-thread, reusing the shared present pipeline.
extension GuiWindow {
    /// Attach the panel above its parent so it tracks the parent's moves. Runs
    /// placement first so the recorded parent-relative offset is the placed one.
    func attachAsChild() {
        assert(role == .popup, "attachAsChild is popup-only")
        guard let parent = popupParent else { return }
        applyPlacement()
        parent.window.addChildWindow(window, ordered: .above)
        assert(window.parent === parent.window, "popup is attached to its parent")
    }

    /// Detach before hide/close: AppKit requires removeChildWindow before the
    /// child deallocates. A no-op when the parent already died (weak → nil).
    func detachFromParent() {
        assert(role == .popup, "detachFromParent is popup-only")
        guard let parent = popupParent, window.parent === parent.window else { return }
        parent.window.removeChildWindow(window)
        assert(window.parent == nil, "detached popup has no parent window")
    }

    /// Synchronous dismissal teardown: detach from the parent, then hide. Called
    /// during a cascade so a closing parent never holds an attached child and no
    /// descendant lingers on screen awaiting the guest's win_destroy.
    func detachAndHide() {
        assert(role == .popup, "detachAndHide is popup-only")
        detachFromParent()
        window.orderOut(nil)
        assert(!window.isVisible, "hidden popup is not visible")
    }

    /// A popup commit carries no serial authority: resize to the client's buffer
    /// points and re-place with the anchor's top-left fixed (growth moves only the
    /// bottom edge, since the parent-relative y grows downward from the anchor).
    func applyPopupCommit(_ commit: GuiCommit) {
        assert(role == .popup, "applyPopupCommit is popup-only")
        assert(commit.win == win, "popup commit routed to the wrong win")
        let content = GuiSizing.bufferPoints(
            widthPx: commit.width, heightPx: commit.height, scaleE12: commit.scaleE12)
        guard content.width >= 1, content.height >= 1 else { return }
        popupSize = content
        applyPlacement()
    }

    /// xdg_popup.reposition: adopt the new parent-relative origin and re-place.
    func popupReposition(posX: Int32, posY: Int32) {
        assert(role == .popup, "reposition is popup-only")
        popupOffset = (x: Double(posX), y: Double(posY))
        applyPlacement()
    }

    /// Set the panel frame from the pure placement math against the parent's live
    /// content-view top-left, sliding to fit the parent screen's visible area.
    func applyPlacement() {
        assert(role == .popup, "placement is popup-only")
        guard let parent = popupParent else { return }
        let screen = window.screen ?? parent.window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let anchor = parent.contentTopLeftInScreen()
        let frame = GuiPopupPlacement.place(
            parentContentTopLeft: anchor, offsetX: popupOffset.x, offsetY: popupOffset.y,
            size: popupSize, visibleFrame: visible)
        window.setFrame(frame, display: true)
    }

    /// This window's content-view top-left in screen coordinates — the anchor a
    /// child popup places against, whether this window is a toplevel or a popup.
    func contentTopLeftInScreen() -> CGPoint {
        let rectInScreen = window.convertToScreen(view.frame)
        assert(rectInScreen.width >= 0, "content rect width is non-negative")
        assert(rectInScreen.height >= 0, "content rect height is non-negative")
        return CGPoint(x: rectInScreen.minX, y: rectInScreen.maxY)
    }
}
