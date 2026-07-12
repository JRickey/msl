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
        let store = RegistryStore(home: home)
        let updated = try store.update { registry in
            try registry.setDefault(name: name)
        }
        assert(updated.defaultDistro == name, "saved default must match the requested distro")
        print("default is now \(name)")
    }
}
