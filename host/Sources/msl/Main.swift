import ArgumentParser

@main
struct MSL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msl",
        abstract: "WSL2-like Linux subsystem for macOS (M0 host).",
        subcommands: [BootCommand.self])
}
