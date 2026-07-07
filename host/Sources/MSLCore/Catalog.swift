import Foundation

public enum CatalogStatus: String, Codable, Sendable {
    case recommended
    case experimental
}

public enum CatalogArtifactKind: String, Codable, Sendable {
    case rootfsTar
}

public struct CatalogArtifact: Codable, Equatable, Sendable {
    public let arch: String
    public let kind: CatalogArtifactKind
    public let compression: TarCompression
    public let url: String
    public let sha256: String
    public let sizeBytes: UInt64

    public init(
        arch: String, kind: CatalogArtifactKind, compression: TarCompression, url: String,
        sha256: String, sizeBytes: UInt64
    ) {
        self.arch = arch
        self.kind = kind
        self.compression = compression
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

public enum CatalogIconKind: String, Codable, Sendable {
    case icns
    case png
    case svg
}

public struct CatalogIcon: Codable, Equatable, Sendable {
    public let kind: CatalogIconKind
    public let url: String
    public let sha256: String
    public let sizeBytes: UInt64
    public let backgroundHex: String?

    public init(
        kind: CatalogIconKind, url: String, sha256: String, sizeBytes: UInt64,
        backgroundHex: String? = nil
    ) {
        self.kind = kind
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.backgroundHex = backgroundHex
    }
}

public struct CatalogVersion: Codable, Equatable, Sendable {
    public let version: String
    public let aliases: [String]
    public let status: CatalogStatus
    public let artifact: CatalogArtifact
    public let icon: CatalogIcon?
    public let defaultUser: String?
    public let imageSizeGiB: Int
    public let notes: String

    public init(
        version: String, aliases: [String], status: CatalogStatus, artifact: CatalogArtifact,
        icon: CatalogIcon?, defaultUser: String?, imageSizeGiB: Int, notes: String
    ) {
        self.version = version
        self.aliases = aliases
        self.status = status
        self.artifact = artifact
        self.icon = icon
        self.defaultUser = defaultUser
        self.imageSizeGiB = imageSizeGiB
        self.notes = notes
    }
}

public struct CatalogFamily: Codable, Equatable, Sendable {
    public let name: String
    public let friendlyName: String
    public let defaultVersion: String
    public let aliases: [String]
    public let versions: [CatalogVersion]

    public init(
        name: String, friendlyName: String, defaultVersion: String, aliases: [String],
        versions: [CatalogVersion]
    ) {
        self.name = name
        self.friendlyName = friendlyName
        self.defaultVersion = defaultVersion
        self.aliases = aliases
        self.versions = versions
    }
}

public struct CatalogResolved: Equatable, Sendable {
    public let family: CatalogFamily
    public let version: CatalogVersion
    public let artifact: CatalogArtifact

    public init(family: CatalogFamily, version: CatalogVersion, artifact: CatalogArtifact) {
        self.family = family
        self.version = version
        self.artifact = artifact
    }

    public var selector: String { "\(family.name)@\(version.version)" }
}

public struct CatalogRow: Equatable, Sendable {
    public let name: String
    public let version: String
    public let status: CatalogStatus
    public let description: String
}

public struct Catalog: Codable, Equatable, Sendable {
    public let schema: Int
    public let generatedAt: String
    public let families: [CatalogFamily]

    public static func loadEmbedded() throws -> Catalog {
        let data = Data(Self.embeddedJSON.utf8)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        guard schema == 1 else { throw MSLError.configuration("unsupported catalog schema") }
        var familyKeys = Set<String>()
        for family in families {  // bounded: embedded catalog
            try validate(family: family, seen: &familyKeys)
        }
    }

    public func listRows(includeExperimental: Bool) -> [CatalogRow] {
        return selectable(includeExperimental: includeExperimental).map { resolved in
            CatalogRow(
                name: resolved.family.name, version: resolved.version.version,
                status: resolved.version.status, description: resolved.version.notes)
        }
    }

    public func selectable(includeExperimental: Bool) -> [CatalogResolved] {
        var rows: [CatalogResolved] = []
        for family in families {  // bounded: embedded catalog
            for version in family.versions
            where includeExperimental || version.status == .recommended {
                rows.append(
                    CatalogResolved(family: family, version: version, artifact: version.artifact))
            }
        }
        return rows.sorted { $0.selector < $1.selector }
    }

    public func resolve(selector: String) throws -> CatalogResolved {
        let parts = try SelectorParts.parse(selector)
        for family in families {  // bounded: embedded catalog
            guard family.matches(parts.family) else { continue }
            let version = try resolveVersion(parts.version, in: family)
            return CatalogResolved(family: family, version: version, artifact: version.artifact)
        }
        throw MSLError.invalidArgument(
            "unknown catalog distro '\(parts.family)'; use 'msl catalog list'")
    }

    public static func isValidSelectorSyntax(_ selector: String) -> Bool {
        return (try? SelectorParts.parse(selector)) != nil
    }

    private func resolveVersion(_ key: String?, in family: CatalogFamily) throws -> CatalogVersion {
        let wanted = key ?? family.defaultVersion
        for version in family.versions where version.matches(wanted) {  // bounded: family versions
            return version
        }
        throw MSLError.invalidArgument(
            "unknown catalog version '\(wanted)' for \(family.name); use 'msl catalog list'")
    }
}

private struct SelectorParts {
    let family: String
    let version: String?

    static func parse(_ selector: String) throws -> SelectorParts {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MSLError.invalidArgument("empty catalog selector") }
        guard trimmed.count <= 96, trimmed.allSatisfy(Self.isSelectorScalar) else {
            throw MSLError.invalidArgument("invalid catalog selector: \(selector)")
        }
        let pieces = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let first = pieces.first, !first.isEmpty else {
            throw MSLError.invalidArgument("invalid catalog selector: \(selector)")
        }
        let version = pieces.count == 2 ? String(pieces[1]) : nil
        if let version, version.isEmpty {
            throw MSLError.invalidArgument("invalid catalog selector: \(selector)")
        }
        return SelectorParts(family: String(first), version: version)
    }

    private static func isSelectorScalar(_ scalar: Character) -> Bool {
        return scalar.isASCII
            && (scalar.isLetter || scalar.isNumber || scalar == "-"
                || scalar == "." || scalar == "@")
    }
}

extension CatalogFamily {
    fileprivate func matches(_ key: String) -> Bool {
        let folded = key.lowercased()
        return name.lowercased() == folded || aliases.contains { $0.lowercased() == folded }
    }
}

extension CatalogVersion {
    fileprivate func matches(_ key: String) -> Bool {
        let folded = key.lowercased()
        return version.lowercased() == folded || aliases.contains { $0.lowercased() == folded }
    }
}

extension Catalog {
    private func validate(family: CatalogFamily, seen: inout Set<String>) throws {
        try insert(key: family.name, into: &seen, label: "catalog family")
        for alias in family.aliases {  // bounded: embedded catalog aliases
            try insert(key: alias, into: &seen, label: "catalog family alias")
        }
        guard family.versions.contains(where: { $0.matches(family.defaultVersion) }) else {
            throw MSLError.configuration("catalog default missing for \(family.name)")
        }
        var versionKeys = Set<String>()
        for version in family.versions {  // bounded: embedded catalog versions
            try validate(version: version, family: family.name, seen: &versionKeys)
        }
    }

    private func validate(
        version: CatalogVersion, family: String, seen: inout Set<String>
    ) throws {
        try insert(key: version.version, into: &seen, label: "\(family) version")
        for alias in version.aliases {  // bounded: embedded catalog aliases
            try insert(key: alias, into: &seen, label: "\(family) version alias")
        }
        try validateArtifact(version.artifact)
        if let icon = version.icon {
            try validateIcon(icon)
        }
        guard (InstallPlan.minSizeGiB...InstallPlan.maxSizeGiB).contains(version.imageSizeGiB)
        else {
            throw MSLError.configuration("catalog image size out of range for \(family)")
        }
        if let user = version.defaultUser, !Registry.isValidUser(user) {
            throw MSLError.configuration("catalog default user invalid for \(family)")
        }
    }

    private func validateArtifact(_ artifact: CatalogArtifact) throws {
        guard artifact.arch == "arm64" else {
            throw MSLError.configuration("catalog arch unsupported")
        }
        guard artifact.url.hasPrefix("https://") else {
            throw MSLError.configuration("catalog URL must be HTTPS: \(artifact.url)")
        }
        guard artifact.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else {
            throw MSLError.configuration("catalog SHA256 invalid for \(artifact.url)")
        }
    }

    private func validateIcon(_ icon: CatalogIcon) throws {
        guard icon.url.hasPrefix("https://") else {
            throw MSLError.configuration("catalog icon URL must be HTTPS: \(icon.url)")
        }
        guard icon.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else {
            throw MSLError.configuration("catalog icon SHA256 invalid for \(icon.url)")
        }
        guard (1...5_000_000).contains(icon.sizeBytes) else {
            throw MSLError.configuration("catalog icon size out of range")
        }
        if let backgroundHex = icon.backgroundHex {
            guard
                backgroundHex.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil
            else {
                throw MSLError.configuration("catalog icon background color invalid")
            }
        }
    }

    private func insert(key: String, into seen: inout Set<String>, label: String) throws {
        let folded = key.lowercased()
        guard !folded.isEmpty else { throw MSLError.configuration("\(label) is empty") }
        guard seen.insert(folded).inserted else {
            throw MSLError.configuration("duplicate \(label): \(key)")
        }
    }
}
