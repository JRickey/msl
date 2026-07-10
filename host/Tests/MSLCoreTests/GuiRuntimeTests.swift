import Foundation
import XCTest

@testable import MSLCore

final class GuiRuntimeEnvironmentTests: XCTestCase {
    func testSessionEnvironmentCarriesRuntimeDirectory() {
        let env = GuiRuntime.environment(runtimeDir: "/run/user/1000")
        XCTAssertEqual(env["WAYLAND_DISPLAY"], "msl-way-0")
        XCTAssertEqual(env["XDG_RUNTIME_DIR"], "/run/user/1000")
        XCTAssertEqual(env["LIBGL_ALWAYS_SOFTWARE"], "1")
        XCTAssertNil(env["DISPLAY"])
    }

    func testEnablePlanNamesPackagesAndInstallScriptIsSeparate() {
        let plan = GuiRuntime.enablePlan()
        XCTAssertTrue(plan.contains("xkb-data"), plan)
        XCTAssertFalse(GuiRuntime.enableInstallScript().isEmpty)
    }
}
