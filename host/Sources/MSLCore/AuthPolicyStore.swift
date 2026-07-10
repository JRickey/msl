import Darwin
import Foundation

/// Writes under `$MSL_HOME/auth/`. The file is created 0600 *before* any bytes
/// land in it and then renamed over the target, so a secret-adjacent file is
/// never briefly world-readable at the umask default.
enum AuthSecureFile {
    static func write(_ data: Data, to url: URL) throws {
        precondition(!data.isEmpty, "refusing to write an empty auth file")
        precondition(url.isFileURL, "auth file url must be a file url")
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(Token.generate()).tmp")
        guard
            FileManager.default.createFile(
                atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw MSLError.io("cannot create \(temp.path)") }
        do {
            try data.write(to: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard Darwin.rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw MSLError.io("rename \(temp.path) failed: errno=\(code)")
        }
    }

    static func ensureDirectory(_ directory: URL) throws {
        precondition(directory.isFileURL, "auth directory url must be a file url")
        assert(!directory.path.isEmpty, "auth directory path must not be empty")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

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

    public func set(
        distro: String, secrets: Bool?, sshAgent: Bool?,
        sshAgentForwarding: AuthForwardingPolicy? = nil
    ) throws {
        guard Registry.isValidName(distro) else {
            throw MSLError.invalidArgument("invalid distro name: \(distro)")
        }
        var file = try load()
        var policy = file.distros[distro] ?? AuthPolicy()
        if let secrets { policy.secrets = secrets }
        if let sshAgent { policy.sshAgent = sshAgent }
        if let sshAgentForwarding { policy.sshAgentForwarding = sshAgentForwarding }
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
        assert(file.version == 1, "only v1 policy is written")
        assert(!url.path.isEmpty, "policy url must have a path")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try AuthSecureFile.write(data, to: url)
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
