public enum AuthSessionWrapper {
    public static let path = "/run/msl/tools/msl-session"

    public static func wrap(_ argv: [String]) -> [String] {
        precondition(!argv.isEmpty, "auth wrapper argv must not be empty")
        return [path, "--"] + argv
    }
}
