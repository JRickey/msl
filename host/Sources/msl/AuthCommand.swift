import ArgumentParser
import Foundation
import MSLCore

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Inspect Mac-native auth service bridges.",
        subcommands: [Status.self, Policy.self])

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show Secret Service and SSH agent bridge status.")

        @Argument(help: "Distro name. Defaults to the registry default.")
        var distro: String?

        func run() throws {
            let status = try DaemonClient.authStatus(MSLHome.resolve(), name: distro)
            print("distro: \(status.distro)")
            print("ssh-agent: \(format(status.sshAgent, detail: status.sshAgentDetail))")
            print("ssh-agent-forwarding: \(status.sshAgentForwarding.rawValue)")
            print("secrets: \(format(status.secrets, detail: status.secretsDetail))")
            print("secrets-bus: \(status.secretsBus)")
        }

        private func format(_ available: Bool, detail: String?) -> String {
            let prefix = available ? "available" : "unavailable"
            guard let detail else { return prefix }
            return "\(prefix) (\(detail))"
        }
    }

    struct Policy: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "policy",
            abstract: "Inspect or update per-distro auth bridge policy.")

        @Argument(help: "Distro name. Defaults to the registry default.")
        var distro: String?

        @Option(help: "Set Secret Service policy: on or off.")
        var secrets: Toggle?

        @Option(name: .customLong("ssh-agent"), help: "Set SSH agent policy: on or off.")
        var sshAgent: Toggle?

        @Option(
            name: .customLong("ssh-agent-forwarding"),
            help: "Set remote SSH agent forwarding policy: off, ask, or on.")
        var sshAgentForwarding: AuthForwardingPolicy?

        func run() throws {
            let home = MSLHome.resolve()
            let name = try Registry.load(from: home.registryURL).resolveDefault(requested: distro)
                .name
            let store = AuthPolicyStore(url: home.authPolicyURL)
            if secrets != nil || sshAgent != nil || sshAgentForwarding != nil {
                try store.set(
                    distro: name,
                    secrets: secrets?.boolValue,
                    sshAgent: sshAgent?.boolValue,
                    sshAgentForwarding: sshAgentForwarding)
            }
            let policy = try store.policy(for: name)
            print("distro: \(name)")
            print("ssh-agent: \(format(policy.sshAgent))")
            print("secrets: \(policy.secrets ? "on" : "off")")
            print("ssh-agent-forwarding: \(policy.sshAgentForwarding.rawValue)")
        }

        private func format(_ value: Bool?) -> String {
            guard let value else { return "auto" }
            return value ? "on" : "off"
        }
    }
}

enum Toggle: String, ExpressibleByArgument {
    case on
    case off

    var boolValue: Bool {
        switch self {
        case .on: return true
        case .off: return false
        }
    }
}

extension AuthForwardingPolicy: ExpressibleByArgument {}
