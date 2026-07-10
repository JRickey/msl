import ArgumentParser
import Darwin
import Foundation
import MSLCore
import MSLGui

/// Hidden prototype-gate command (ADR 0011): present a distro's remote Wayland
/// toplevels as native windows and record the latency ledger. Drives the
/// daemon's existing VM; not wired into multi-distro plumbing.
struct GuiSpikeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gui-spike",
        abstract: "Present a distro's remote GUI windows natively (prototype gate).",
        shouldDisplay: false)

    @Argument(help: "Distro whose compositor to present (default: the registry default).")
    var name: String?

    @Option(name: .long, help: "CSV path for the latency ledger.")
    var csv: String = "./gui-spike.csv"

    func run() throws {
        let home = MSLHome.resolve()
        try DaemonClient.ensureRunning(home)
        let fd = try openSurfacePlane(home)
        let channel = try GuiChannel(fd: fd)
        let path = csv
        let label = name ?? "default"
        MainActor.assumeIsolated {
            GuiPresenter(channel: channel, distro: label, csvPath: path).run()
        }
    }

    private func openSurfacePlane(_ home: MSLHome) throws -> Int32 {
        let control = try DaemonClient.connect(home)
        defer { control.close() }
        do {
            return try control.guiConnectRaw(name: name)
        } catch {
            let message = (error as? MSLError)?.description ?? error.localizedDescription
            FileHandle.standardError.write(
                Data("gui-spike: cannot reach guest compositor: \(message)\n".utf8))
            throw ExitCode(1)
        }
    }
}
