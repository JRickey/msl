import AppKit
import Foundation

/// Layer-backed content view: turns NSEvents into window-local logical
/// coordinates (top-left origin, y flipped from AppKit's bottom-left) and
/// forwards them to its `GuiWindow`. Modifier keys are tracked so each
/// flagsChanged toggles a down/up on the specific key.
@MainActor
final class GuiSurfaceView: NSView {
    weak var owner: GuiWindow?
    var cursor: NSCursor = .arrow

    private var tracking: NSTrackingArea?
    private var downModifiers: Set<UInt16> = []
    private var hasEntered = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Convert an event's window location to window-local logical coordinates
    /// with the origin at the top-left (Wayland/evdev convention).
    private func localPoint(_ event: NSEvent) -> (posX: Double, posY: Double) {
        let inView = convert(event.locationInWindow, from: nil)
        let flippedY = Double(bounds.height) - Double(inView.y)
        return (Double(inView.x), flippedY)
    }

    /// The occlusion verdict for a tracking event: whether this surface is the
    /// topmost msl window under the cursor. Cheap — one CG lookup and a set hit.
    private func occlusion(_ event: NSEvent) -> GuiPointerFilter.Decision {
        guard let owner, let host = window else { return .forward }
        let screen = host.convertPoint(toScreen: event.locationInWindow)
        let topmost = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
        return GuiPointerFilter.decide(
            topmostWindowNumber: topmost, selfWindowNumber: host.windowNumber,
            topmostIsOurs: owner.ownsWindowNumber(topmost), hasEntered: hasEntered)
    }

    /// Send a tracking event only while this surface owns the cursor; when another
    /// of our windows covers the point, emit one leave and then stay silent.
    private func routeTracking(_ event: NSEvent, presence: Bool, _ forward: () -> Void) {
        switch occlusion(event) {
        case .forward:
            hasEntered = presence
            forward()
        case .suppress:
            break
        case .leaveOnce:
            hasEntered = false
            let point = localPoint(event)
            owner?.pointerCrossing(entered: false, posX: point.posX, posY: point.posY)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        routeTracking(event, presence: true) {
            let point = localPoint(event)
            owner?.pointerMotion(posX: point.posX, posY: point.posY)
        }
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) { button(event, GuiButton.left, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, GuiButton.left, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, GuiButton.right, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, GuiButton.right, down: false) }
    override func otherMouseDown(with event: NSEvent) {
        button(event, GuiButton.middle, down: true)
    }
    override func otherMouseUp(with event: NSEvent) {
        button(event, GuiButton.middle, down: false)
    }

    private func button(_ event: NSEvent, _ code: UInt32, down: Bool) {
        let point = localPoint(event)
        owner?.pointerButton(button: code, down: down, posX: point.posX, posY: point.posY)
    }

    override func scrollWheel(with event: NSEvent) {
        routeTracking(event, presence: true) {
            let point = localPoint(event)
            owner?.pointerAxis(
                dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                posX: point.posX, posY: point.posY)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        routeTracking(event, presence: true) {
            let point = localPoint(event)
            owner?.pointerCrossing(entered: true, posX: point.posX, posY: point.posY)
        }
    }

    override func mouseExited(with event: NSEvent) {
        routeTracking(event, presence: false) {
            let point = localPoint(event)
            owner?.pointerCrossing(entered: false, posX: point.posX, posY: point.posY)
        }
    }

    override func keyDown(with event: NSEvent) {
        owner?.keyEvent(virtualCode: event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        owner?.keyEvent(virtualCode: event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        // CapsLock fires one flagsChanged per toggle, and xkb toggles caps on
        // press — so each macOS toggle must arrive as a full press+release.
        if code == GuiKeymap.virtualCapsLock {
            owner?.keyEvent(virtualCode: code, down: true)
            owner?.keyEvent(virtualCode: code, down: false)
            return
        }
        let down = !downModifiers.contains(code)
        if down {
            downModifiers.insert(code)
        } else {
            downModifiers.remove(code)
        }
        owner?.keyEvent(virtualCode: code, down: down)
    }
}
