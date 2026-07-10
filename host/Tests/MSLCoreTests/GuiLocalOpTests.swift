import Foundation
import XCTest

@testable import MSLCore

final class GuiLocalOpTests: XCTestCase {
    func testGuiTokenRoundTrip() throws {
        let cases: [LocalRequest] = [
            .guiToken(name: "ubuntu", user: "devuser"), .guiToken(name: nil, user: nil),
        ]
        for request in cases {
            XCTAssertEqual(try LocalRequest.decode(try request.encoded()), request)
        }
    }

    func testGuiAttachRoundTrip() throws {
        let cases: [LocalRequest] = [
            .guiAttach(distro: "ubuntu", user: "devuser", token: String(repeating: "a", count: 32)),
            .guiAttach(distro: "ubuntu", user: nil, token: String(repeating: "b", count: 32)),
        ]
        for request in cases {
            XCTAssertEqual(try LocalRequest.decode(try request.encoded()), request)
        }
    }

    /// The untokenized surface-plane op must not survive on the wire.
    func testGuiConnectOpIsRejected() {
        let frame = Data("{\"op\":\"gui_connect\",\"name\":\"ubuntu\"}".utf8)
        XCTAssertThrowsError(try LocalRequest.decode(frame))
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

    func testGuiAttachUsesOpName() throws {
        let data = try LocalRequest.guiAttach(distro: "d", user: nil, token: "cafe").encoded()
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"gui_attach\""), json)
        XCTAssertTrue(json.contains("\"token\":\"cafe\""), json)
    }

    func testGuiLaunchUsesStructuredOpName() throws {
        let req = GuiLaunchReq(distro: "d", argv: ["/bin/true"], env: [:], cwd: nil)
        let data = try LocalRequest.guiLaunch(req).encoded()
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"gui_launch\""), json)
        XCTAssertTrue(json.contains("\"distro\":\"d\""), json)
    }
}
