import AppKit
import Foundation
import MSLCore
import MSLMenuBarCore

/// Owns the menu-bar status item and rebuilds its menu on open. State is read
/// only when the menu opens (no timers, no polling): a synchronous placeholder
/// shows immediately, then an off-main probe refreshes the still-open menu.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let home: MSLHome
    private let installer: InstallService
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(home: MSLHome, installer: InstallService) {
        self.home = home
        self.installer = installer
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "msl")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "msl"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        assert(menu === self.menu, "delegate serves only its own menu")
        rebuild(with: nil)
        let home = self.home
        Task { @MainActor [weak self] in
            let probe = await StatusProbe.probeAsync(home: home)
            self?.rebuild(with: MenuModel.make(probe: probe))
        }
    }

    private func rebuild(with model: MenuModel?) {
        menu.removeAllItems()
        appendHeader(model)
        menu.addItem(.separator())
        appendDistros(model)
        menu.addItem(.separator())
        appendActions(model)
        menu.addItem(.separator())
        menu.addItem(action(title: "Quit msl", selector: #selector(quit)))
    }

    private func appendHeader(_ model: MenuModel?) {
        guard let model else {
            menu.addItem(disabled(title: "Checking daemon…"))
            return
        }
        menu.addItem(disabled(title: model.daemonTitle))
        if let vmTitle = model.vmTitle {
            menu.addItem(disabled(title: vmTitle))
        }
    }

    private func appendDistros(_ model: MenuModel?) {
        guard let model, model.daemon == .running else { return }
        guard !model.distros.isEmpty else {
            menu.addItem(disabled(title: "No distros installed"))
            return
        }
        for row in model.distros {  // bounded: registry list
            let mark = row.isDefault ? " (default)" : ""
            let detail = "\(row.state), \(row.sessions) sessions\(mark)"
            menu.addItem(disabled(title: "\(row.name) — \(detail)"))
        }
    }

    private func appendActions(_ model: MenuModel?) {
        let start = action(title: "Start daemon", selector: #selector(startDaemon))
        start.isEnabled = model?.startEnabled ?? false
        menu.addItem(start)
        let stop = action(title: "Shut down", selector: #selector(shutDown))
        stop.isEnabled = model?.shutDownEnabled ?? false
        menu.addItem(stop)
        menu.addItem(action(title: "Install distro…", selector: #selector(installDistro)))
    }

    @objc private func startDaemon() {
        let home = self.home
        Task { @MainActor in
            if let error = await DaemonAction.start(home: home) {
                Notifier.postDaemon(title: "Start daemon failed", message: error)
            }
        }
    }

    @objc private func shutDown() {
        let home = self.home
        Task { @MainActor in
            if let error = await DaemonAction.shutdown(home: home) {
                Notifier.postDaemon(title: "Shut down failed", message: error)
            }
        }
    }

    @objc private func installDistro() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [MSLBundleType.contentType]
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installer.requestInstall(url: url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func disabled(title: String) -> NSMenuItem {
        assert(!title.isEmpty, "menu item needs a title")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(title: String, selector: Selector) -> NSMenuItem {
        assert(!title.isEmpty, "menu item needs a title")
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }
}
