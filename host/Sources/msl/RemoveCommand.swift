import ArgumentParser
import Foundation
import MSLCore

struct RemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a distro: its image, lock sidecar, and registry entry.")

    @Argument(help: "Distro name to remove.")
    var name: String

    @Flag(name: .long, help: "Keep the image file; only drop the registry entry.")
    var keepImage: Bool = false

    func run() throws {
        let home = MSLHome.resolve()
        var registry = try Registry.load(from: home.registryURL)
        guard registry.entry(name: name) != nil else {
            throw MSLError.invalidArgument("no such distro: \(name)")
        }
        do {
            try ImageLock.deleteHoldingLock(
                imagePath: home.imageURL(name: name).path, keepImage: keepImage)
        } catch {
            let reason = (error as? MSLError)?.description ?? "\(error)"
            throw MSLError.configuration("cannot remove \(name): \(reason)")
        }
        try registry.remove(name: name)
        try registry.save(to: home.registryURL)
        let note = registry.defaultDistro == nil ? " (set a new default with 'msl default')" : ""
        print("removed \(name)\(note)")
    }
}
