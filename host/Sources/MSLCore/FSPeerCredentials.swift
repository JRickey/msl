import Darwin
import Foundation
import Security

/// Decides whether a connected appex fd may be admitted. Injectable so the
/// listener can be tested with a stub instead of a real signed peer.
public protocol FSAuthenticator: Sendable {
    func admit(fd: Int32) -> Bool
}

/// Kernel-attested peer identity from a connected `AF_UNIX` socket.
public struct FSPeerCredentials: Sendable {
    public let euid: UInt32
    public let epid: Int32
    public let auditToken: Data
}

/// Production authenticator: reads the peer euid and audit token, requires the
/// euid to match the daemon's own uid, and validates the audit token against a
/// pinned designated requirement for the FSKit appex.
public struct FSPeerAuthenticator: FSAuthenticator {
    private let daemonUID: UInt32
    private let requirement: String

    public init(daemonUID: UInt32 = UInt32(getuid()), requirement: String) {
        precondition(!requirement.isEmpty, "requirement must not be empty")
        self.daemonUID = daemonUID
        self.requirement = requirement
    }

    public func admit(fd: Int32) -> Bool {
        guard fd >= 0, let creds = Self.read(fd: fd) else { return false }
        let drPassed = Self.validate(auditToken: creds.auditToken, requirement: requirement)
        return FSAdmission.admit(peerUID: creds.euid, daemonUID: daemonUID, drPassed: drPassed)
    }

    /// Read `LOCAL_PEERCRED` (euid), `LOCAL_PEEREPID`, and `LOCAL_PEERTOKEN`.
    public static func read(fd: Int32) -> FSPeerCredentials? {
        precondition(fd >= 0, "peer fd must be valid")
        guard let euid = peerEUID(fd), let epid = peerEPID(fd), let token = peerToken(fd) else {
            return nil
        }
        assert(token.count == MemoryLayout<audit_token_t>.size, "audit token is 32 bytes")
        return FSPeerCredentials(euid: euid, epid: epid, auditToken: token)
    }

    /// Validate the audit token against a designated requirement (pass == true).
    public static func validate(auditToken: Data, requirement: String) -> Bool {
        guard auditToken.count == MemoryLayout<audit_token_t>.size, !requirement.isEmpty else {
            return false
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
            let requirementRef = req
        else { return false }
        let attrs = [kSecGuestAttributeAudit: auditToken as CFData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
            let codeRef = code
        else { return false }
        return SecCodeCheckValidity(codeRef, [], requirementRef) == errSecSuccess
    }

    private static func peerEUID(_ fd: Int32) -> UInt32? {
        assert(fd >= 0, "fd must be valid")
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let rc = withUnsafeMutablePointer(to: &cred) {
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, $0, &len)
        }
        guard rc == 0, cred.cr_version == UInt32(XUCRED_VERSION) else { return nil }
        return cred.cr_uid
    }

    private static func peerEPID(_ fd: Int32) -> Int32? {
        assert(fd >= 0, "fd must be valid")
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEEREPID, &pid, &len) == 0 else { return nil }
        return pid
    }

    private static func peerToken(_ fd: Int32) -> Data? {
        assert(fd >= 0, "fd must be valid")
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) {
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &len)
        }
        guard rc == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return withUnsafeBytes(of: token) { Data($0) }
    }
}

/// Test/stub authenticator with a fixed verdict.
public struct FSStaticAuthenticator: FSAuthenticator {
    private let verdict: Bool
    public init(admit: Bool) { self.verdict = admit }
    public func admit(fd: Int32) -> Bool { return verdict }
}
