import Foundation
import XCTest

@testable import MSLCore

final class FSAdmissionTests: XCTestCase {
    func testAdmitRequiresBothUIDMatchAndDRPass() {
        XCTAssertTrue(FSAdmission.admit(peerUID: 501, daemonUID: 501, drPassed: true))
        XCTAssertFalse(FSAdmission.admit(peerUID: 501, daemonUID: 501, drPassed: false))
        XCTAssertFalse(FSAdmission.admit(peerUID: 0, daemonUID: 501, drPassed: true))
        XCTAssertFalse(FSAdmission.admit(peerUID: 502, daemonUID: 501, drPassed: false))
    }

    func testRequirementPinsIdentifierAnchorAndTeam() {
        let req = FSAdmission.requirement(bundleID: "dev.msl.app.fsmodule", teamID: "REDACTED_TEAM_ID")
        XCTAssertTrue(req.contains("identifier \"dev.msl.app.fsmodule\""))
        XCTAssertTrue(req.contains("anchor apple generic"))
        XCTAssertTrue(req.contains("certificate leaf[subject.OU] = \"REDACTED_TEAM_ID\""))
    }

    func testReconcileReturnsOnlyUnknownMounts() {
        let discovered = ["/u/msl/ubuntu", "/u/msl/debian", "/u/msl/arch"]
        let known: Set<String> = ["/u/msl/debian"]
        XCTAssertEqual(
            FSAdmission.reconcile(discovered: discovered, known: known),
            ["/u/msl/arch", "/u/msl/ubuntu"])
    }

    func testFreshDaemonReclaimsEveryDiscoveredMount() {
        let discovered = ["/u/msl/ubuntu", "/u/msl/debian"]
        XCTAssertEqual(
            FSAdmission.reconcile(discovered: discovered, known: []),
            ["/u/msl/debian", "/u/msl/ubuntu"])
    }

    func testStaticAuthenticatorHonorsVerdict() {
        XCTAssertTrue(FSStaticAuthenticator(admit: true).admit(fd: 3))
        XCTAssertFalse(FSStaticAuthenticator(admit: false).admit(fd: 3))
    }
}
