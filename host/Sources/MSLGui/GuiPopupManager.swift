import AppKit
import Foundation
import MSLCore

/// Host-owned popup dismissal: the guest closes popups on clicks it routes, but
/// app deactivation, another window taking key, and chrome clicks never reach a
/// remote surface — the host observes those and tells the guest to dismiss. Sends
/// `popup_dismiss`; the guest cascades the grab stack and a duplicate no-ops.
@MainActor
final class GuiPopupManager: NSObject {
    private let channel: GuiChannel
    private var panels: [UInt32: NSWindow] = [:]
    private var parents: [UInt32: UInt32] = [:]
    private var mouseMonitor: Any?
    private var onDetach: (@MainActor (UInt32) -> Void)?

    static let maxPopups = 64

    init(channel: GuiChannel) {
        self.channel = channel
        super.init()
    }

    /// Install the app-level observers and record how to synchronously detach a
    /// popup from its parent (removeChildWindow) during a dismissal cascade.
    func begin(onDetach: @MainActor @escaping (UInt32) -> Void) {
        self.onDetach = onDetach
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(appResignedActive),
            name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// Process-shutdown teardown: drop the observers and any live monitor.
    func end() {
        let center = NotificationCenter.default
        center.removeObserver(
            self, name: NSApplication.didResignActiveNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        removeMouseMonitor()
        onDetach = nil
    }

    var hasCapacity: Bool { panels.count < GuiPopupManager.maxPopups }

    /// Track a live popup; the mouse-down monitor exists only while ≥1 is live.
    /// Callers gate on `hasCapacity` first, so the cap is a real drop, not a trap.
    func register(win: UInt32, parent: UInt32, panel: NSWindow) {
        assert(panels.count < GuiPopupManager.maxPopups, "caller gated on hasCapacity")
        assert(win != parent, "a popup cannot be its own parent")
        let wasEmpty = panels.isEmpty
        panels[win] = panel
        parents[win] = parent
        if wasEmpty { installMouseMonitor() }
    }

    /// Drop a popup; the monitor is removed on the 1→0 edge.
    func unregister(win: UInt32) {
        guard panels.removeValue(forKey: win) != nil else { return }
        parents.removeValue(forKey: win)
        if panels.isEmpty { removeMouseMonitor() }
        assert(panels.count == parents.count, "panel and parent maps stay in step")
    }

    /// Dismiss every live popup (app-deactivation and other-window-key cases).
    func dismissAll() {
        guard !panels.isEmpty else { return }
        for win in panels.keys {  // bounded: ≤ maxPopups
            dismiss(win: win)
        }
    }

    /// A parent (toplevel or popup) is closing: synchronously detach and hide its
    /// whole descendant popup subtree, then dismiss each, so no parent NSWindow
    /// closes while still holding an attached child, and a nested popup does not
    /// linger visible until the guest's async win_destroy arrives.
    func dismissChildren(of parentWin: UInt32) {
        let doomed = descendants(of: parentWin)
        assert(doomed.count <= panels.count, "descendant set stays within tracked popups")
        assert(!doomed.contains(parentWin), "a parent is never its own descendant")
        for win in doomed {  // bounded: ≤ maxPopups
            onDetach?(win)
            dismiss(win: win)
        }
    }

    /// Breadth-first descendant walk over the parent map (nested menus chain).
    /// Bounded by the popup cap and deduped, so a malformed cycle cannot loop.
    private func descendants(of root: UInt32) -> [UInt32] {
        assert(GuiPopupManager.maxPopups >= 1, "the cap bounds the walk")
        var result: [UInt32] = []
        var frontier: Set<UInt32> = [root]
        for _ in 0..<GuiPopupManager.maxPopups {  // bounded: ≤ maxPopups levels
            var next: Set<UInt32> = []
            for (child, parent) in parents where frontier.contains(parent) {
                guard !result.contains(child) else { continue }
                result.append(child)
                next.insert(child)
            }
            if next.isEmpty { break }
            frontier = next
        }
        assert(result.count <= parents.count, "descendant set cannot exceed tracked popups")
        return result
    }

    @objc private func appResignedActive() {
        dismissAll()
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard !panels.isEmpty else { return }
        guard let key = note.object as? NSWindow, !isPopupPanel(key) else { return }
        dismissAll()
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observeMouseDown(event) }
            return event
        }
        assert(mouseMonitor != nil, "local mouse monitor installed while popups live")
    }

    private func removeMouseMonitor() {
        guard let monitor = mouseMonitor else { return }
        NSEvent.removeMonitor(monitor)
        mouseMonitor = nil
        assert(mouseMonitor == nil, "monitor cleared when no popup remains")
    }

    /// Dismiss only for chrome clicks (title bar — downs that never reach a
    /// content view). A down inside any content view — popup or parent — is the
    /// guest's decision: it consumes outside-grab presses itself, and a host
    /// dismissal racing ahead of the press re-arms the client's menu toggle.
    private func observeMouseDown(_ event: NSEvent) {
        guard !panels.isEmpty else { return }
        guard let target = event.window else { return }
        if isPopupPanel(target) { return }
        if let content = target.contentView {
            let local = content.convert(event.locationInWindow, from: nil)
            if content.bounds.contains(local) { return }
        }
        dismissAll()
    }

    private func isPopupPanel(_ window: NSWindow) -> Bool {
        assert(!panels.isEmpty, "identity check only runs while popups live")
        for panel in panels.values where panel === window {  // bounded: ≤ maxPopups
            return true
        }
        return false
    }

    /// Send `popup_dismiss` for one win — tracked (cascade) or refused (over cap).
    func dismiss(win: UInt32) {
        guard let payload = try? GuiProto.encode(GuiPopupDismiss(win: win)) else { return }
        assert(payload.count <= GuiProto.maxFrame, "dismiss payload fits the frame bound")
        channel.send(type: GuiType.popupDismiss.rawValue, flags: 0, payload: payload)
    }
}
