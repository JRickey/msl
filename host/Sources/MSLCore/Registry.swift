import Foundation

/// One installed distro. `image` is the basename under `distros/`; the absolute
/// path is resolved against `MSLHome` so a relocated home stays valid.
public struct DistroEntry: Codable, Sendable, Equatable {
    public let name: String
    public let image: String
    public let hostname: String
    public let createdAt: String

    public init(name: String, image: String, hostname: String, createdAt: String) {
        self.name = name
        self.image = image
        self.hostname = hostname
        self.createdAt = createdAt
    }
}

/// The on-disk distro registry (`registry.json`). Pure value type: all mutations
/// go through the methods below, which enforce name validity and default rules;
/// persistence is `load`/`save` with an atomic (tmp+rename) write.
public struct Registry: Codable, Sendable, Equatable {
    public private(set) var version: Int
    public private(set) var defaultDistro: String?
    public private(set) var distros: [DistroEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case defaultDistro = "default"
        case distros
    }

    public init(version: Int = 1, defaultDistro: String? = nil, distros: [DistroEntry] = []) {
        self.version = version
        self.defaultDistro = defaultDistro
        self.distros = distros
    }

    /// The distro-name grammar from the protocol: `^[a-z][a-z0-9-]{0,31}$`.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...32).contains(name.count) else { return false }
        var isFirst = true
        for ch in name.unicodeScalars {  // bounded: at most 32 scalars
            let lower = ("a"..."z").contains(ch)
            let digit = ("0"..."9").contains(ch)
            if isFirst {
                guard lower else { return false }
                isFirst = false
            } else {
                guard lower || digit || ch == "-" else { return false }
            }
        }
        return true
    }

    public func entry(name: String) -> DistroEntry? {
        return distros.first { $0.name == name }
    }

    /// Register a new distro. Rejects an invalid or duplicate name; the first
    /// distro ever registered becomes the default.
    public mutating func add(_ entry: DistroEntry) throws {
        guard Self.isValidName(entry.name) else {
            throw MSLError.invalidArgument("invalid distro name: \(entry.name)")
        }
        guard self.entry(name: entry.name) == nil else {
            throw MSLError.configuration("distro already registered: \(entry.name)")
        }
        distros.append(entry)
        if defaultDistro == nil { defaultDistro = entry.name }
    }

    /// Remove a distro. Clearing the default when it names the removed distro is
    /// deliberate: the caller must set a new default explicitly.
    public mutating func remove(name: String) throws {
        guard entry(name: name) != nil else {
            throw MSLError.invalidArgument("no such distro: \(name)")
        }
        distros.removeAll { $0.name == name }
        if defaultDistro == name { defaultDistro = nil }
    }

    /// Point the default at an existing distro.
    public mutating func setDefault(name: String) throws {
        guard entry(name: name) != nil else {
            throw MSLError.invalidArgument("no such distro: \(name)")
        }
        defaultDistro = name
    }

    /// Resolve which distro `msl up` should boot: an explicit `--distro`
    /// (`requested`) wins; otherwise the registry default; otherwise an error.
    /// An unknown name is an error either way (flag > registry > error).
    public func resolveDefault(requested: String?) throws -> DistroEntry {
        guard let name = requested ?? defaultDistro else {
            throw MSLError.configuration(
                "no default distro; install one with 'msl install' or pass --distro/--rootfs")
        }
        guard let match = entry(name: name) else {
            throw MSLError.invalidArgument("no such distro: \(name) (see 'msl list')")
        }
        return match
    }

    /// Load the registry from disk. A missing file is a genuinely fresh, empty
    /// registry; a present-but-empty/truncated file is an error (never silently
    /// treated as fresh). Decoded contents are validated before use.
    public static func load(from url: URL) throws -> Registry {
        guard FileManager.default.fileExists(atPath: url.path) else { return Registry() }
        let data = try Data(contentsOf: url)
        let whitespaceOnly =
            String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
        guard !data.isEmpty, !whitespaceOnly else {
            throw MSLError.configuration(
                "registry.json is empty/truncated — restore or delete it: \(url.path)")
        }
        let registry: Registry
        do {
            registry = try JSONDecoder().decode(Registry.self, from: data)
        } catch {
            throw MSLError.configuration("registry.json is corrupt: \(error) [\(url.path)]")
        }
        try registry.validate(source: url.path)
        return registry
    }

    /// Reject a corrupt/hostile registry before any path is derived from it:
    /// every name valid + unique, images exactly `<name>.img` (no separators or
    /// traversal), and the default naming an installed distro.
    private func validate(source: String) throws {
        var seen = Set<String>()
        for entry in distros {  // bounded: registry list
            guard Self.isValidName(entry.name) else {
                throw MSLError.configuration("invalid distro name '\(entry.name)' in \(source)")
            }
            guard seen.insert(entry.name).inserted else {
                throw MSLError.configuration("duplicate distro '\(entry.name)' in \(source)")
            }
            guard entry.image == "\(entry.name).img" else {
                throw MSLError.configuration(
                    "image for '\(entry.name)' must be '\(entry.name).img' in \(source)")
            }
        }
        if let name = defaultDistro, self.entry(name: name) == nil {
            throw MSLError.configuration("default '\(name)' names no installed distro in \(source)")
        }
    }

    /// Persist atomically (Foundation `.atomic` = write temp, then rename).
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
