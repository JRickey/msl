import AppKit
import MSLMenuBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    var showMenuBarItem: Bool {
        didSet {
            guard showMenuBarItem != oldValue else { return }
            onShowMenuBarItemChanged(showMenuBarItem)
        }
    }

    private let onShowMenuBarItemChanged: @MainActor (Bool) -> Void

    init(
        preferences: AppPreferences,
        onShowMenuBarItemChanged: @escaping @MainActor (Bool) -> Void
    ) {
        self.showMenuBarItem = preferences.showMenuBarItem
        self.onShowMenuBarItemChanged = onShowMenuBarItemChanged
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        preferences: AppPreferences,
        onShowMenuBarItemChanged: @escaping @MainActor (Bool) -> Void
    ) {
        let model = SettingsModel(
            preferences: preferences,
            onShowMenuBarItemChanged: onShowMenuBarItemChanged
        )
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        let autosavesFrame = window.setFrameAutosaveName("MSLSettingsWindow")
        super.init(window: window)
        assert(!window.isReleasedWhenClosed, "closing Settings must preserve the reusable window")
        assert(autosavesFrame, "Settings window placement must persist")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is programmatic")
    }

    func present() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        assert(window.isVisible, "presented Settings window must be visible")
    }
}
