import Foundation

public struct AuthStatusData: Sendable, Equatable, Codable {
    public static let secretsBusRequired =
        "DBUS_SESSION_BUS_ADDRESS or distro dbus-daemon/dbus-broker-launch"
    public static let secretsBusNotRequired = "not required"

    public let distro: String
    public let sshAgent: Bool
    public let secrets: Bool
    public let sshAgentDetail: String?
    public let secretsBus: String
    public let secretsDetail: String?

    enum CodingKeys: String, CodingKey {
        case distro
        case sshAgent = "ssh_agent"
        case secrets
        case sshAgentDetail = "ssh_agent_detail"
        case secretsBus = "secrets_bus"
        case secretsDetail = "secrets_detail"
    }

    public init(
        distro: String, sshAgent: Bool, secrets: Bool, sshAgentDetail: String? = nil,
        secretsBus: String? = nil, secretsDetail: String? = nil
    ) {
        precondition(!distro.isEmpty, "auth status distro must not be empty")
        self.distro = distro
        self.sshAgent = sshAgent
        self.secrets = secrets
        self.sshAgentDetail = sshAgentDetail
        self.secretsBus = secretsBus ?? Self.defaultSecretsBus(secrets: secrets)
        self.secretsDetail = secretsDetail
    }

    private static func defaultSecretsBus(secrets: Bool) -> String {
        secrets ? secretsBusRequired : secretsBusNotRequired
    }
}
