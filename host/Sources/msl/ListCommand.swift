import ArgumentParser
import MSLCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed distros with their state, image size, and hostname.")

    func run() throws {
        let home = MSLHome.resolve()
        let inventory = try DistroInventoryService.snapshot(home: home)
        guard !inventory.items.isEmpty else {
            print("no distros installed (use 'msl install')")
            return
        }
        print("NAME              STATE       SIZE        HOSTNAME")
        for item in inventory.items {  // bounded: registry list
            let entry = item.entry
            let state = item.isDefault ? "default" : "registered"
            let size =
                item.storage.imagePresent
                ? IECByteFormatter.string(from: item.storage.allocatedBytes) : "missing"
            let line = pad(entry.name, 18) + pad(state, 12) + pad(size, 12) + entry.hostname
            print(line)
        }
    }

    private func pad(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }
}
