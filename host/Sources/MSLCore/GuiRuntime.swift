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
        return environment(runtimeDir: runtimeDir, x11Display: nil)
    }

    /// The GUI session environment, injecting `DISPLAY` only when the compositor
    /// announced an X11 display. A session without XWayland leaves `DISPLAY`
    /// unset so X11 clients fail fast rather than dialing a dead socket.
    public static func environment(
        runtimeDir: String, x11Display: String?
    ) -> [String: String] {
        precondition(!runtimeDir.isEmpty, "GUI runtime directory must not be empty")
        var values = environment
        values["XDG_RUNTIME_DIR"] = runtimeDir
        if let display = x11Display, !display.isEmpty {
            values["DISPLAY"] = display
        }
        return values
    }

    public static func enablePlan() -> String {
        return GuiEnablement.ubuntu.plan()
    }

    public static func enableInstallScript() -> String {
        return GuiEnablement.ubuntu.installScript()
    }
}
