import Darwin
import Foundation
import Security

/// Peer identity read from a connected `AF_UNIX` socket: the kernel-attested
/// effective uid/pid plus the audit token used for a Security-framework
/// designated-requirement check. None of these can be forged by the client.
struct PeerIdentity: Sendable {
    let euid: uid_t
    let epid: pid_t
    let auditToken: Data
}

enum PeerAuth {
    static func requirement(teamID: String) -> String {
        precondition(!teamID.isEmpty, "team id must not be empty")
        return "identifier \"dev.msl.app.fsmodule\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Read `LOCAL_PEERCRED`, `LOCAL_PEEREPID`, and `LOCAL_PEERTOKEN` from the
    /// accepted socket. Returns nil if the kernel denies any credential read.
    static func identity(fd: Int32) -> PeerIdentity? {
        precondition(fd >= 0, "peer fd must be valid")
        guard let euid = peerEUID(fd) else { return nil }
        guard let epid = peerEPID(fd) else { return nil }
        guard let token = peerAuditToken(fd) else { return nil }
        assert(token.count == MemoryLayout<audit_token_t>.size, "audit token is 32 bytes")
        return PeerIdentity(euid: euid, epid: epid, auditToken: token)
    }

    private static func peerEUID(_ fd: Int32) -> uid_t? {
        assert(fd >= 0, "fd must be valid")
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let rc = withUnsafeMutablePointer(to: &cred) {
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, $0, &len)
        }
        guard rc == 0, cred.cr_version == UInt32(XUCRED_VERSION) else { return nil }
        return cred.cr_uid
    }

    private static func peerEPID(_ fd: Int32) -> pid_t? {
        assert(fd >= 0, "fd must be valid")
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let rc = getsockopt(fd, SOL_LOCAL, LOCAL_PEEREPID, &pid, &len)
        guard rc == 0 else { return nil }
        return pid
    }

    private static func peerAuditToken(_ fd: Int32) -> Data? {
        assert(fd >= 0, "fd must be valid")
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) {
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &len)
        }
        guard rc == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return withUnsafeBytes(of: token) { Data($0) }
    }

    /// Validate the peer's audit token against a designated requirement. Returns
    /// the OSStatus (`errSecSuccess` = pass) so the caller can log pass/fail.
    static func validate(auditToken: Data, requirement: String) -> OSStatus {
        precondition(auditToken.count == MemoryLayout<audit_token_t>.size, "token is 32 bytes")
        precondition(!requirement.isEmpty, "requirement must not be empty")
        var req: SecRequirement?
        let rr = SecRequirementCreateWithString(requirement as CFString, [], &req)
        guard rr == errSecSuccess, let requirementRef = req else { return rr }
        let attrs = [kSecGuestAttributeAudit: auditToken as CFData] as CFDictionary
        var code: SecCode?
        let cr = SecCodeCopyGuestWithAttributes(nil, attrs, [], &code)
        guard cr == errSecSuccess, let codeRef = code else { return cr }
        return SecCodeCheckValidity(codeRef, [], requirementRef)
    }
}
