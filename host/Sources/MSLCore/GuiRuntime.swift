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

    public static func probeScript() -> String {
        return """
            uid="$(id -u)"
            runtime="${XDG_RUNTIME_DIR:-/run/user/$uid}"
            printf 'runtime_dir=%s\\n' "$runtime"
            [ -x /run/msl/tools/msl-way ] && echo "msl_way=present" || echo "msl_way=missing"
            [ -d /usr/share/X11/xkb ] && echo "xkb_data=present" || echo "xkb_data=missing"
            if command -v gtk4-widget-factory >/dev/null 2>&1; then
              echo "gtk4_widget_factory=present"
            else
              echo "gtk4_widget_factory=missing"
            fi
            command -v gimp >/dev/null 2>&1 && echo "gimp=present" || echo "gimp=missing"
            exit 0
            """
    }

    public static func startScript(distro: String) -> String {
        let quotedDistro = UserWrap.shellQuote(distro)
        return commonPrelude()
            + """
            pattern='/run/msl/tools/msl-way.*--wayland-socket msl-way-0'
            if pgrep -u "$(id -u)" -f "$pattern" >/dev/null 2>&1; then
              echo "state=running"
              exit 0
            fi
            MSL_DISTRO=\(quotedDistro) XDG_RUNTIME_DIR="$runtime" \\
              nohup /run/msl/tools/msl-way --wayland-socket \(waylandDisplay) \\
              > "$runtime/msl-way.log" 2>&1 < /dev/null &
            for i in $(seq 1 40); do
              [ -S "$runtime/\(waylandDisplay)" ] && echo "state=running" && exit 0
              sleep 0.1
            done
            [ -f "$runtime/msl-way.log" ] && tail -40 "$runtime/msl-way.log" >&2
            echo "state=failed"
            exit 46
            """
    }

    public static func statusScript() -> String {
        return """
            uid="$(id -u)"
            if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
              runtime="$XDG_RUNTIME_DIR"
            elif [ -S "/run/user/$uid/\(waylandDisplay)" ]; then
              runtime="/run/user/$uid"
            else
              runtime="/tmp/msl-gui-$uid"
            fi
            pattern='/run/msl/tools/msl-way.*--wayland-socket msl-way-0'
            if pgrep -u "$uid" -f "$pattern" >/dev/null 2>&1; then
              state=running
            else
              state=stopped
            fi
            printf 'state=%s\\n' "$state"
            printf 'runtime_dir=%s\\n' "$runtime"
            printf 'wayland=%s\\n' "\(waylandDisplay)"
            [ -S "$runtime/\(waylandDisplay)" ] && echo "socket=present" || echo "socket=missing"
            [ -f "$runtime/msl-way.log" ] && tail -20 "$runtime/msl-way.log"
            exit 0
            """
    }

    public static func stopScript() -> String {
        return """
            uid="$(id -u)"
            pattern='/run/msl/tools/msl-way.*--wayland-socket msl-way-0'
            if pgrep -u "$uid" -f "$pattern" >/dev/null 2>&1; then
              pkill -u "$uid" -f "$pattern" || true
              echo "state=stopping"
            else
              echo "state=stopped"
            fi
            exit 0
            """
    }

    public static func launchScript(command: [String]) -> String {
        precondition(!command.isEmpty, "GUI launch command must not be empty")
        var script = commonPrelude()
        for (key, value) in env {  // bounded: fixed environment list
            script += "export \(key)=\(UserWrap.shellQuote(value))\n"
        }
        script += "exec" + commandLine(command) + "\n"
        return script
    }

    public static func launchBackgroundScript(command: [String]) -> String {
        precondition(!command.isEmpty, "GUI launch command must not be empty")
        var script = commonPrelude()
        for (key, value) in env {  // bounded: fixed environment list
            script += "export \(key)=\(UserWrap.shellQuote(value))\n"
        }
        script += "nohup" + commandLine(command) + " > /dev/null 2>&1 < /dev/null &\n"
        script += "echo launched\n"
        return script
    }

    public static func enablePlan() -> String {
        return GuiEnablement.ubuntu.plan()
    }

    public static func enableInstallScript() -> String {
        return GuiEnablement.ubuntu.installScript()
    }

    private static func commonPrelude() -> String {
        return """
            set -eu
            uid="$(id -u)"
            runtime="${XDG_RUNTIME_DIR:-}"
            if [ -z "$runtime" ]; then
              runtime="/tmp/msl-gui-$uid"
            fi
            if ! mkdir -p "$runtime" 2>/dev/null; then
              runtime="/tmp/msl-gui-$uid"
              mkdir -p "$runtime"
            fi
            chmod 700 "$runtime" 2>/dev/null || true
            export XDG_RUNTIME_DIR="$runtime"
            if [ ! -x /run/msl/tools/msl-way ]; then
              echo "missing=/run/msl/tools/msl-way" >&2
              exit 44
            fi
            if [ ! -d /usr/share/X11/xkb ]; then
              echo "missing=xkb-data" >&2
              exit 45
            fi
            """
    }

    private static func commandLine(_ command: [String]) -> String {
        var line = ""
        for arg in command {  // bounded: user argv count
            line += " " + UserWrap.shellQuote(arg)
        }
        assert(!line.isEmpty, "command line must include at least one argument")
        return line
    }
}
