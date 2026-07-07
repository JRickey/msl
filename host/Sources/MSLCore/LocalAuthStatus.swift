import Foundation

public struct AuthStatusData: Sendable, Equatable, Codable {
    public let distro: String
    public let sshAgent: Bool
    public let secrets: Bool

    enum CodingKeys: String, CodingKey {
        case distro
        case sshAgent = "ssh_agent"
        case secrets
    }

    public init(distro: String, sshAgent: Bool, secrets: Bool) {
        precondition(!distro.isEmpty, "auth status distro must not be empty")
        self.distro = distro
        self.sshAgent = sshAgent
        self.secrets = secrets
    }
}
