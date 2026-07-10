import Foundation
import XCTest

@testable import MSLCore

final class AuthSessionTableTests: XCTestCase {
    private let running: (String) -> Bool = { _ in true }

    func testCreatePublishesGuestEnvironment() {
        let table = AuthSessionTable()
        let session = table.create(
            distro: "ubuntu", sshAgent: true, sshAgentForwarding: true, secrets: false)
        let env = session.environment

        XCTAssertEqual(env["MSL_AUTH_ID"], session.id)
        XCTAssertEqual(env["MSL_AUTH_TOKEN"], session.token)
        XCTAssertEqual(env["MSL_AUTH_DISTRO"], "ubuntu")
        XCTAssertEqual(env["MSL_AUTH_PORT"], String(Proto.authPort))
        XCTAssertEqual(env["MSL_AUTH_SSH"], "1")
        XCTAssertEqual(env["MSL_AUTH_SSH_FORWARDING"], "1")
        XCTAssertEqual(env["MSL_AUTH_SECRETS"], "0")
        XCTAssertEqual(env["MSL_AUTH_VERSION"], "1")
    }

    func testValidateAcceptsMatchingPeerAndEnabledSurface() throws {
        let table = AuthSessionTable()
        let session = table.create(distro: "ubuntu", sshAgent: true, secrets: false)
        XCTAssertFalse(session.sshAgentForwarding)
        let peer = AuthPeer(
            id: session.id, token: session.token, distro: "ubuntu", uid: 1000, pid: 42,
            comm: "ssh")

        XCTAssertEqual(try table.validate(peer, surface: .sshAgent, isRunning: running), session)
    }

    func testValidateRejectsWrongToken() {
        let table = AuthSessionTable()
        let session = table.create(distro: "ubuntu", sshAgent: true, secrets: false)
        let peer = AuthPeer(
            id: session.id, token: "wrong", distro: "ubuntu", uid: nil, pid: nil, comm: nil)

        XCTAssertThrowsError(
            try table.validate(peer, surface: .sshAgent, isRunning: running)
        ) { error in
            XCTAssertEqual((error as? AuthValidationError)?.code, .denied)
        }
    }

    func testValidateRejectsDisabledSurface() {
        let table = AuthSessionTable()
        let session = table.create(distro: "ubuntu", sshAgent: false, secrets: false)
        let peer = AuthPeer(
            id: session.id, token: session.token, distro: "ubuntu", uid: nil, pid: nil,
            comm: nil)

        XCTAssertThrowsError(
            try table.validate(peer, surface: .sshAgent, isRunning: running)
        ) { error in
            XCTAssertEqual((error as? AuthValidationError)?.code, .denied)
        }
    }

    func testValidateRejectsSessionWhoseDistroStopped() {
        let table = AuthSessionTable()
        let session = table.create(distro: "ubuntu", sshAgent: true, secrets: false)
        let peer = AuthPeer(
            id: session.id, token: session.token, distro: "ubuntu", uid: nil, pid: nil,
            comm: nil)

        XCTAssertThrowsError(
            try table.validate(peer, surface: .sshAgent, isRunning: { _ in false })
        ) { error in
            XCTAssertEqual((error as? AuthValidationError)?.code, .denied)
            XCTAssertEqual((error as? AuthValidationError)?.message, "distro is not running")
        }
    }

    func testRemovingGuestSessionRevokesAuth() {
        let table = AuthSessionTable()
        let session = table.create(distro: "ubuntu", sshAgent: true, secrets: false)
        let peer = AuthPeer(
            id: session.id, token: session.token, distro: "ubuntu", uid: nil, pid: nil,
            comm: nil)

        table.bind(authID: session.id, guestSessionID: 7)
        table.removeGuestSession(7)

        XCTAssertThrowsError(
            try table.validate(peer, surface: .sshAgent, isRunning: running)
        ) { error in
            XCTAssertEqual((error as? AuthValidationError)?.code, .denied)
        }
    }
}
