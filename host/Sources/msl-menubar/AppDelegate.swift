import AppKit
import Foundation
import MSLCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let home = MSLHome.resolve()
    private var mainWindow: MainWindowController?
    private var statusController: StatusController?
    private var installer: InstallService?

    func applicationWillFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        let installer = InstallService(home: home)
        let mainWindow = MainWindowController(home: home)
        self.installer = installer
        self.mainWindow = mainWindow
        self.statusController = StatusController(
            home: home, installer: installer, openMainWindow: { mainWindow.present() })
        Notifier.requestAuthorization()
        assert(self.installer != nil, "install service must precede document open events")
        assert(self.mainWindow != nil, "main window must exist for launch presentation")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindow?.present()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        mainWindow?.present()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let installer else { return }
        assert(!urls.isEmpty, "open delivered no urls")
        for url in urls where url.isFileURL {  // bounded: Finder selection
            installer.requestInstall(url: url)
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")
        let appItem = NSMenuItem()
        let windowItem = NSMenuItem()
        let appMenu = NSMenu(title: "MSL")
        let windowMenu = NSMenu(title: "Window")
        mainMenu.addItem(appItem)
        mainMenu.addItem(windowItem)
        appItem.submenu = appMenu
        windowItem.submenu = windowMenu
        addMenuItem(
            to: appMenu, title: "About MSL",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        appMenu.addItem(.separator())
        addMenuItem(
            to: appMenu, title: "Hide MSL", action: #selector(NSApplication.hide(_:)), key: "h")
        appMenu.addItem(.separator())
        addMenuItem(
            to: appMenu, title: "Quit MSL", action: #selector(NSApplication.terminate(_:)), key: "q"
        )
        addMenuItem(
            to: windowMenu, title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            key: "m")
        addMenuItem(to: windowMenu, title: "Zoom", action: #selector(NSWindow.performZoom(_:)))
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        assert(NSApp.mainMenu === mainMenu, "regular app requires a main menu")
        assert(NSApp.windowsMenu === windowMenu, "window commands require a window menu")
    }

    private func addMenuItem(
        to menu: NSMenu, title: String, action: Selector, key: String = ""
    ) {
        precondition(!title.isEmpty, "menu title must not be empty")
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        assert(item.action == action, "menu item must retain its action")
    }
}
