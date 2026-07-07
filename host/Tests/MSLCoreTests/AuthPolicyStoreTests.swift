import Foundation
import XCTest

@testable import MSLCore

final class AuthPolicyStoreTests: XCTestCase {
    func testDefaultsEnableSecretsAndInheritSshAgent() throws {
        let store = AuthPolicyStore(url: tempURL())
        let policy = try store.policy(for: "ubuntu")

        XCTAssertTrue(policy.secrets)
        XCTAssertNil(policy.sshAgent)
        XCTAssertEqual(policy.sshAgentForwarding, .off)
    }

    func testSetPersistsDistroPolicyWithOwnerOnlyMode() throws {
        let url = tempURL()
        let store = AuthPolicyStore(url: url)

        try store.set(distro: "ubuntu", secrets: false, sshAgent: true)
        let loaded = try AuthPolicyStore(url: url).policy(for: "ubuntu")

        XCTAssertFalse(loaded.secrets)
        XCTAssertEqual(loaded.sshAgent, true)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    func testRejectsInvalidDistroName() {
        let store = AuthPolicyStore(url: tempURL())
        XCTAssertThrowsError(try store.policy(for: "../bad"))
    }

    private func tempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-auth-policy-\(UUID().uuidString)")
        return dir.appendingPathComponent("policy.json")
    }
}
