import Foundation

public struct GuiPackageManifest: Sendable, Equatable {
    public let family: String
    public let manager: String
    public let packages: [String]

    public init(family: String, manager: String, packages: [String]) {
        precondition(!family.isEmpty, "manifest family must not be empty")
        precondition(!manager.isEmpty, "manifest manager must not be empty")
        precondition(!packages.isEmpty, "manifest packages must not be empty")
        self.family = family
        self.manager = manager
        self.packages = packages
    }

    public func plan() -> String {
        assert(!packages.isEmpty, "manifest packages must not be empty")
        return """
            \(family) packages:
              sudo \(manager) update
              sudo \(manager) install -y \(packages.joined(separator: " "))

            X11 applications run through the bundled Xwayland; DISPLAY is set only
            for GUI sessions whose compositor announced an X11 display.
            """
    }

    public func installScript() -> String {
        assert(!packages.isEmpty, "manifest packages must not be empty")
        return """
            set -eu
            if ! command -v \(manager) >/dev/null 2>&1; then
              echo "unsupported package manager" >&2
              echo "install \(packages.joined(separator: ", "))" >&2
              exit 2
            fi
            sudo \(manager) update
            sudo \(manager) install -y \(packages.joined(separator: " "))
            """
    }
}

public enum GuiEnablement {
    public static let ubuntu = GuiPackageManifest(
        family: "Ubuntu/Debian",
        manager: "apt-get",
        packages: [
            "xkb-data",
            "xwayland",
            "mesa-utils",
            "libgl1",
            "libegl1",
            "libgtk-4-bin",
            "libgtk-3-bin",
            "qt6-wayland",
            "wayland-utils",
        ])

    public static func manifest(osRelease: String) -> GuiPackageManifest? {
        let fields = parseOSRelease(osRelease)
        let id = fields["ID"] ?? ""
        let like = fields["ID_LIKE"] ?? ""
        guard !id.isEmpty || !like.isEmpty else { return nil }
        let tokens = ([id] + like.split(separator: " ").map(String.init)).map { $0.lowercased() }
        if tokens.contains("ubuntu") || tokens.contains("debian") {
            return ubuntu
        }
        return nil
    }

    public static func parseOSRelease(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = unquote(String(parts[1]))
        }
        return fields
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        if trimmed.first == "\"", trimmed.last == "\"" {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
