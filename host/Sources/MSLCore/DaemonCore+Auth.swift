import Foundation

struct ResolvedSession {
    let argv: [String]
    let cwd: String
    let auth: AuthSession
}

extension DaemonCore {
    /// A /mnt/mac cwd cannot exist when the distro opted out of the share.
    func resolveSession(
        name: String, requested: [String]?, cwd requestedCwd: String
    ) throws -> ResolvedSession {
        assert(!name.isEmpty, "distro name must not be empty")
        assert(!requestedCwd.isEmpty, "cwd must not be empty")
        let registry = try Registry.load(from: config.home.registryURL)
        let entry = registry.entry(name: name)
        let shareOn = config.shareHomePath != nil && (entry?.macShare ?? true)
        let cwd = UserWrap.effectiveCwd(requestedCwd, macShare: shareOn)
        let auth = try makeAuthSession(name: name)
        let argv = AuthSessionWrapper.wrap(requested ?? ["/bin/bash", "-l"])
        guard let user = entry?.defaultUser else {
            return ResolvedSession(argv: argv, cwd: cwd, auth: auth)
        }
        return ResolvedSession(
            argv: UserWrap.wrap(user: user, argv: argv, cwd: cwd), cwd: cwd, auth: auth)
    }

    private func makeAuthSession(name: String) throws -> AuthSession {
        assert(!name.isEmpty, "auth session name must not be empty")
        let policy = try AuthPolicyStore(url: config.home.authPolicyURL).policy(for: name)
        let hostAgent = HostSSHAgentProxy().available
        return authSessions.create(
            distro: name, sshAgent: policy.sshAgent ?? hostAgent, secrets: policy.secrets)
    }

    func mergedEnv(_ env: [String: String]?, auth: AuthSession) -> [String: String] {
        var result = env ?? [:]
        if result["TERM"] == nil { result["TERM"] = config.term }
        for (key, value) in auth.environment {
            result[key] = value
        }
        return result
    }
}
