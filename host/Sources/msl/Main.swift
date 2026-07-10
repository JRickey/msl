import ArgumentParser

@main
struct MSL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msl",
        abstract: "WSL2-like Linux subsystem for macOS (M2 host).",
        subcommands: [
            BootCommand.self, UpCommand.self, InstallCommand.self, ListCommand.self,
            RemoveCommand.self, DefaultCommand.self, ConfigCommand.self, DaemonCommand.self,
            ShellCommand.self, RunCommand.self, StatusCommand.self, StopCommand.self,
            ShutdownCommand.self, ExportCommand.self,
            GuiCommand.self,
            MountCommand.self, UnmountCommand.self, FSKitCommand.self, CatalogCommand.self,
            LauncherCommand.self, DesktopCommand.self, AuthCommand.self,
        ])
}
