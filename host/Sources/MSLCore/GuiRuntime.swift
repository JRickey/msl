import Foundation

public struct GuiRuntimeReport: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(_ data: ExecData) {
        self.exitCode = data.exitCode
        self.stdout = data.stdout
        self.stderr = data.stderr
    }
}

public enum GuiRuntime {
    public static let waylandDisplay = "msl-way-0"

    public static let env: [(String, String)] = [
        ("WAYLAND_DISPLAY", waylandDisplay),
        ("GDK_BACKEND", "wayland,x11"),
        ("QT_QPA_PLATFORM", "wayland;xcb"),
        ("SDL_VIDEODRIVER", "wayland,x11"),
        ("CLUTTER_BACKEND", "wayland"),
        ("LIBGL_ALWAYS_SOFTWARE", "1"),
        ("MESA_LOADER_DRIVER_OVERRIDE", "llvmpipe"),
    ]

    public static var environment: [String: String] {
        return Dictionary(uniqueKeysWithValues: env)
    }

    public static func environment(runtimeDir: String) -> [String: String] {
        precondition(!runtimeDir.isEmpty, "GUI runtime directory must not be empty")
        var values = environment
        values["XDG_RUNTIME_DIR"] = runtimeDir
        return values
    }

    public static func enablePlan() -> String {
        return GuiEnablement.ubuntu.plan()
    }

    public static func enableInstallScript() -> String {
        return GuiEnablement.ubuntu.installScript()
    }
}
