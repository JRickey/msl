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

    func testDisplayInjectedOnlyWhenAnnounced() {
        let with = GuiRuntime.environment(runtimeDir: "/run/user/1000", x11Display: ":0")
        XCTAssertEqual(with["DISPLAY"], ":0")
        XCTAssertEqual(with["XDG_RUNTIME_DIR"], "/run/user/1000")

        let without = GuiRuntime.environment(runtimeDir: "/run/user/1000", x11Display: nil)
        XCTAssertNil(without["DISPLAY"], "no DISPLAY without an announced X11 display")

        let empty = GuiRuntime.environment(runtimeDir: "/run/user/1000", x11Display: "")
        XCTAssertNil(empty["DISPLAY"], "an empty display string is not injected")
    }

    func testEnablePlanIncludesXwayland() {
        XCTAssertTrue(GuiRuntime.enablePlan().contains("xwayland"), GuiRuntime.enablePlan())
    }

    func testEnablePlanNamesPackagesAndInstallScriptIsSeparate() {
        let plan = GuiRuntime.enablePlan()
        XCTAssertTrue(plan.contains("xkb-data"), plan)
        XCTAssertFalse(GuiRuntime.enableInstallScript().isEmpty)
    }
}
