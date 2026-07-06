import AppKit
import Foundation
import MSLCore

@MainActor
final class CatalogInstallPanel: NSObject {
    struct Choice {
        let resolved: CatalogResolved
        let installedName: String
    }

    private let catalog: Catalog
    private var entries: [CatalogResolved] = []
    private let popup = NSPopUpButton(frame: NSRect(x: 0, y: 58, width: 360, height: 26))
    private let nameField = NSTextField(frame: NSRect(x: 0, y: 26, width: 170, height: 24))
    private let detail = NSTextField(labelWithString: "")
    private let experimental = NSButton(
        checkboxWithTitle: "Show experimental", target: nil, action: nil)

    private init(catalog: Catalog) {
        self.catalog = catalog
        super.init()
        experimental.target = self
        experimental.action = #selector(toggleExperimental)
        popup.target = self
        popup.action = #selector(updateDetail)
        configureDetail()
        reloadEntries()
    }

    static func choose(catalog: Catalog) -> Choice? {
        let panel = CatalogInstallPanel(catalog: catalog)
        let alert = panel.makeAlert()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            return try panel.choice()
        } catch {
            panel.warn(error)
            return nil
        }
    }

    private func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Install from Catalog"
        alert.informativeText = "Choose a distro and optional installed name."
        alert.accessoryView = accessoryView()
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private func accessoryView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.frame = NSRect(x: 184, y: 30, width: 80, height: 18)
        experimental.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        view.addSubview(popup)
        view.addSubview(nameLabel)
        view.addSubview(nameField)
        view.addSubview(detail)
        view.addSubview(experimental)
        return view
    }

    private func configureDetail() {
        detail.frame = NSRect(x: 0, y: 90, width: 360, height: 20)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.textColor = .secondaryLabelColor
    }

    private func reloadEntries() {
        entries = catalog.selectable(includeExperimental: experimental.state == .on)
        popup.removeAllItems()
        for entry in entries {  // bounded: embedded catalog
            popup.addItem(withTitle: Self.title(for: entry))
        }
        updateDetail()
    }

    @objc private func toggleExperimental() {
        reloadEntries()
    }

    @objc private func updateDetail() {
        guard let selected = selected else {
            detail.stringValue = "No catalog entries available"
            return
        }
        if nameField.stringValue.isEmpty {
            nameField.stringValue = selected.family.name
        }
        let hash = String(selected.artifact.sha256.prefix(12))
        detail.stringValue =
            "\(Self.humanBytes(selected.artifact.sizeBytes)) download, sha256 \(hash)..."
    }

    private var selected: CatalogResolved? {
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < entries.count else { return nil }
        return entries[index]
    }

    private func choice() throws -> Choice {
        guard let selected else { throw MSLError.configuration("no catalog entries available") }
        let installName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = installName.isEmpty ? selected.family.name : installName
        guard Registry.isValidName(name) else {
            throw MSLError.invalidArgument("invalid distro name (^[a-z][a-z0-9-]{0,31}$): \(name)")
        }
        return Choice(resolved: selected, installedName: name)
    }

    private func warn(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Catalog install failed"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private static func title(for resolved: CatalogResolved) -> String {
        return
            "\(resolved.family.friendlyName) \(resolved.version.version) (\(resolved.version.status.rawValue))"
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {  // bounded: units.count
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f%@" : "%.1f%@", value, units[unit])
    }
}
