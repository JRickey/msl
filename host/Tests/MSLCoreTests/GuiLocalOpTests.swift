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

    func testGuiConnectUsesOpName() throws {
        let data = try LocalRequest.guiConnect(name: "d").encoded()
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"gui_connect\""), json)
    }
}
