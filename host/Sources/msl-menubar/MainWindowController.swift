import AppKit
import MSLCore
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: MainWindowModel

    init(home: MSLHome) {
        self.model = MainWindowModel(home: home)
        let root = MainWindowView(model: model)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "MSL"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 1100, height: 700)
        window.setContentSize(NSSize(width: 1240, height: 780))
        let autosavesFrame = window.setFrameAutosaveName("MSLMainWindow")
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        assert(window.minSize.width == 1100, "main window minimum width is contractual")
        assert(window.minSize.height == 700, "main window minimum height is contractual")
        assert(autosavesFrame, "main window placement must persist")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is programmatic")
    }

    func present() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refresh()
        assert(window.isVisible, "presented main window must be visible")
    }

    func windowWillClose(_ notification: Notification) {
        assert(notification.object as? NSWindow === window, "delegate owns one window")
    }
}
