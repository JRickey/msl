import ArgumentParser
import Foundation
import MSLCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed distros with their state, image size, and hostname.")

    func run() throws {
        let home = MSLHome.resolve()
        let registry = try Registry.load(from: home.registryURL)
        guard !registry.distros.isEmpty else {
            print("no distros installed (use 'msl install')")
            return
        }
        print("NAME              STATE       SIZE        HOSTNAME")
        for entry in registry.distros {  // bounded: registry list
            let state = registry.defaultDistro == entry.name ? "default" : "registered"
            let size = Self.imageSize(home.imageURL(name: entry.name).path)
            let line = pad(entry.name, 18) + pad(state, 12) + pad(size, 12) + entry.hostname
            print(line)
        }
    }

    private func pad(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }

    /// On-disk (allocated) size of the image; sparse images report far less than
    /// their virtual size, so blocks*512 is the meaningful number.
    private static func imageSize(_ path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { return "missing" }
        let bytes = UInt64(bitPattern: Int64(st.st_blocks)) &* 512
        return humanBytes(bytes)
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
