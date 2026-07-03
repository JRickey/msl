import ArgumentParser
import Foundation
import MSLCore

struct DefaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "default",
        abstract: "Set the default distro used by 'msl up' without --distro.")

    @Argument(help: "Distro name to make the default.")
    var name: String

    func run() throws {
        let home = MSLHome.resolve()
        var registry = try Registry.load(from: home.registryURL)
        try registry.setDefault(name: name)
        try registry.save(to: home.registryURL)
        print("default is now \(name)")
    }
}
