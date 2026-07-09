import XCTest

@testable import MSLCore

final class GuiEnablementTests: XCTestCase {
    func testOSReleaseParserStripsQuotesAndComments() {
        let fields = GuiEnablement.parseOSRelease(
            """
            # distro identity
            ID=ubuntu
            ID_LIKE="debian"
            NAME="Ubuntu"
            MALFORMED
            """)
        XCTAssertEqual(fields["ID"], "ubuntu")
        XCTAssertEqual(fields["ID_LIKE"], "debian")
        XCTAssertEqual(fields["NAME"], "Ubuntu")
        XCTAssertNil(fields["MALFORMED"])
    }

    func testUbuntuManifestSelectedFromID() {
        let manifest = GuiEnablement.manifest(osRelease: "ID=ubuntu\n")
        XCTAssertEqual(manifest, GuiEnablement.ubuntu)
        XCTAssertEqual(manifest?.manager, "apt-get")
    }

    func testDebianLikeManifestSelectedFromIDLike() {
        let manifest = GuiEnablement.manifest(osRelease: "ID=pop\nID_LIKE=\"ubuntu debian\"\n")
        XCTAssertEqual(manifest?.family, "Ubuntu/Debian")
        XCTAssertTrue(manifest?.packages.contains("qt6-wayland") ?? false)
    }

    func testUnknownManifestIsNil() {
        XCTAssertNil(GuiEnablement.manifest(osRelease: "ID=alpine\nID_LIKE=\"busybox\"\n"))
        XCTAssertNil(GuiEnablement.manifest(osRelease: "NAME=unknown\n"))
    }

    func testPlanDoesNotInstall() {
        let plan = GuiEnablement.ubuntu.plan()
        XCTAssertTrue(plan.contains("sudo apt-get install -y"))
        XCTAssertFalse(plan.contains("set -eu"))
    }

    func testInstallScriptIsBoundedToManifestPackages() {
        let script = GuiEnablement.ubuntu.installScript()
        XCTAssertTrue(script.contains("command -v apt-get"))
        XCTAssertTrue(script.contains("sudo apt-get update"))
        XCTAssertTrue(script.contains("libgtk-4-bin"))
    }
}
