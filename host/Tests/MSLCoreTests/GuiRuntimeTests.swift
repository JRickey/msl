import Foundation
import XCTest

@testable import MSLCore

final class GuiRuntimeScriptTests: XCTestCase {
    func testLaunchScriptExportsWaylandEnvironment() {
        let script = GuiRuntime.launchScript(command: ["/usr/bin/gedit", "a b"])
        XCTAssertTrue(script.contains("export WAYLAND_DISPLAY='msl-way-0'"), script)
        XCTAssertTrue(script.contains("export XDG_RUNTIME_DIR=\"$runtime\""), script)
        XCTAssertTrue(script.contains("runtime=\"/tmp/msl-gui-$uid\""), script)
        XCTAssertTrue(script.contains("exec '/usr/bin/gedit' 'a b'"), script)
    }

    func testBackgroundLaunchKeepsRedirectOnCommandLine() {
        let script = GuiRuntime.launchBackgroundScript(command: ["/usr/bin/gimp"])
        XCTAssertTrue(script.contains("nohup '/usr/bin/gimp' > /dev/null 2>&1 < /dev/null &"))
        XCTAssertTrue(script.contains("echo launched"))
        XCTAssertFalse(script.contains("\n > /dev/null"))
    }

    func testStartScriptUsesBoundedSocketWait() {
        let script = GuiRuntime.startScript(distro: "ubuntu")
        XCTAssertTrue(script.contains("MSL_DISTRO='ubuntu'"), script)
        XCTAssertTrue(script.contains("--wayland-socket msl-way-0"), script)
        XCTAssertTrue(script.contains("[ -S \"$runtime/msl-way-0\" ]"), script)
        XCTAssertFalse(script.contains("while true"))
    }

    func testProbeIsSideEffectFree() {
        let script = GuiRuntime.probeScript()
        XCTAssertTrue(script.contains("msl_way=present"), script)
        XCTAssertTrue(script.contains("xkb_data=present"), script)
        XCTAssertFalse(script.contains("apt-get"), script)
    }
}
