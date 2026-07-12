import ArgumentParser
import MSLCore

struct MountCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mount",
        abstract: "Mount a distro's filesystem in Finder at ~/msl/<distro>.")

    @Argument(help: "Distro to mount (default: the registry default).")
    var name: String?

    @Flag(name: .long, help: "Reveal the mountpoint in Finder after mounting.")
    var reveal: Bool = false

    @Flag(name: .long, help: "Mount with writes disabled.")
    var readOnly: Bool = false

    func run() throws {
        let home = MSLHome.resolve()
        let mounted = try FinderMountService().mount(
            home: home, name: name, readOnly: readOnly)
        print("mounted \(mounted.name) at \(mounted.mountpoint)")
        if reveal { Self.reveal(mounted.mountpoint) }
    }

    private static func reveal(_ mountpoint: String) {
        assert(!mountpoint.isEmpty, "mountpoint must not be empty")
        _ = Subprocess.run("/usr/bin/open", [mountpoint])
    }
}
