import Foundation

public enum AuthForwardingPolicy: String, Codable, Sendable, Equatable {
    case off
    case ask
    case on
}

public struct AuthPolicy: Codable, Sendable, Equatable {
    public var secrets: Bool
    public var sshAgent: Bool?
    public var sshAgentForwarding: AuthForwardingPolicy

    enum CodingKeys: String, CodingKey {
        case secrets
        case sshAgent = "ssh_agent"
        case sshAgentForwarding = "ssh_agent_forwarding"
    }

    public init(
        secrets: Bool = true, sshAgent: Bool? = nil,
        sshAgentForwarding: AuthForwardingPolicy = .off
    ) {
        self.secrets = secrets
        self.sshAgent = sshAgent
        self.sshAgentForwarding = sshAgentForwarding
    }
}

public struct AuthPolicyStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func policy(for distro: String) throws -> AuthPolicy {
        guard Registry.isValidName(distro) else {
            throw MSLError.invalidArgument("invalid distro name: \(distro)")
        }
        return try load().distros[distro] ?? AuthPolicy()
    }

    public func set(distro: String, secrets: Bool?, sshAgent: Bool?) throws {
        guard Registry.isValidName(distro) else {
            throw MSLError.invalidArgument("invalid distro name: \(distro)")
        }
        var file = try load()
        var policy = file.distros[distro] ?? AuthPolicy()
        if let secrets { policy.secrets = secrets }
        if let sshAgent { policy.sshAgent = sshAgent }
        file.distros[distro] = policy
        try save(file)
    }

    private func load() throws -> AuthPolicyFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return AuthPolicyFile() }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw MSLError.configuration("auth policy is empty/truncated: \(url.path)")
        }
        let file = try JSONDecoder().decode(AuthPolicyFile.self, from: data)
        try file.validate(source: url.path)
        return file
    }

    private func save(_ file: AuthPolicyFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct AuthPolicyFile: Codable, Sendable, Equatable {
    var version = 1
    var distros: [String: AuthPolicy] = [:]

    func validate(source: String) throws {
        guard version == 1 else {
            throw MSLError.configuration("unsupported auth policy version in \(source)")
        }
        for name in distros.keys {
            guard Registry.isValidName(name) else {
                throw MSLError.configuration("invalid distro name '\(name)' in \(source)")
            }
        }
    }
}
