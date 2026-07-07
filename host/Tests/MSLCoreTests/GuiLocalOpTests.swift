import Foundation
import XCTest

@testable import MSLCore

final class GuiLocalOpTests: XCTestCase {
    func testGuiConnectRoundTrip() throws {
        let cases: [LocalRequest] = [.guiConnect(name: "ubuntu"), .guiConnect(name: nil)]
        for request in cases {
            XCTAssertEqual(try LocalRequest.decode(try request.encoded()), request)
        }
    }

    func testGuiControlOpsRoundTrip() throws {
        let runtime = GuiRuntimeReq(distro: "ubuntu", user: "root")
        let launch = GuiLaunchReq(
            distro: "ubuntu", argv: ["/bin/sh", "-lc", "echo ok"], env: ["A": "B"], cwd: "/")
        let cases: [LocalRequest] = [
            .guiProbe(runtime), .guiStart(runtime), .guiStatus(runtime), .guiStop(runtime),
            .guiLaunch(launch),
        ]
        for request in cases {
            XCTAssertEqual(try LocalRequest.decode(try request.encoded()), request)
        }
    }

    func testGuiConnectUsesOpName() throws {
        let data = try LocalRequest.guiConnect(name: "d").encoded()
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"gui_connect\""), json)
    }

    func testGuiLaunchUsesStructuredOpName() throws {
        let req = GuiLaunchReq(distro: "d", argv: ["/bin/true"], env: [:], cwd: nil)
        let data = try LocalRequest.guiLaunch(req).encoded()
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"gui_launch\""), json)
        XCTAssertTrue(json.contains("\"distro\":\"d\""), json)
    }
}
