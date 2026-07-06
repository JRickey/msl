import Foundation

/// Routing data parsed from an `msl://<distro>` resource URL. This is routing
/// only, never an authorization secret: msld authenticates the peer and
/// validates the mount id and nonce independently.
struct MSLResourceURL: Sendable, Equatable {
    let distro: String
    let mount: String
    let nonce: String
    let readonly: Bool

    /// Parse routing fields; mount/nonce may be empty during FSKit probe, but the
    /// daemon still validates them before load admission.
    static func parse(_ url: URL) -> MSLResourceURL? {
        guard url.scheme == "msl" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let distro = distroComponent(comps)
        guard !distro.isEmpty else { return nil }
        let items = comps.queryItems ?? []
        let parsed = MSLResourceURL(
            distro: distro,
            mount: value(items, name: "mount"),
            nonce: value(items, name: "nonce"),
            readonly: readonlyValue(items))
        assert(!parsed.distro.isEmpty, "distro validated non-empty above")
        return parsed
    }

    /// Distro name from the URL authority. Prefers the host; falls back to the
    /// first non-empty path component for `msl:///name` style inputs.
    private static func distroComponent(_ comps: URLComponents) -> String {
        assert(comps.scheme == "msl", "caller validated scheme")
        if let host = comps.host, !host.isEmpty { return host }
        let trimmed = comps.path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = trimmed.first else { return "" }
        return String(first)
    }

    private static func value(_ items: [URLQueryItem], name: String) -> String {
        precondition(!name.isEmpty, "query name must not be empty")
        for item in items where item.name == name {
            return item.value ?? ""
        }
        return ""
    }

    private static func readonlyValue(_ items: [URLQueryItem]) -> Bool {
        let raw = value(items, name: "readonly").lowercased()
        return !(raw == "0" || raw == "false")
    }
}
