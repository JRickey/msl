import Foundation
import XCTest

@testable import MSLCore

final class LaunchAgentTests: XCTestCase {
    func testRenderContainsExpectedKeys() {
        let plist = LaunchAgent.render(executablePath: "/usr/local/bin/msl")
        XCTAssertTrue(plist.contains("<key>Label</key>"))
        XCTAssertTrue(plist.contains("<string>dev.msl.daemon</string>"))
        XCTAssertTrue(plist.contains("<string>/usr/local/bin/msl</string>"))
        XCTAssertTrue(plist.contains("<string>daemon</string>"))
        XCTAssertTrue(plist.contains("<string>run</string>"))
    }

    func testRenderRunAtLoadAndKeepAlive() {
        let plist = LaunchAgent.render(executablePath: "/opt/msl")
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<true/>"))
        XCTAssertTrue(plist.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(plist.contains("<key>SuccessfulExit</key>"))
        XCTAssertTrue(plist.contains("<false/>"))
    }

    func testRenderHonoursCustomArguments() {
        let plist = LaunchAgent.render(
            executablePath: "/opt/msl", arguments: ["daemon", "run", "--idle-timeout", "0"])
        XCTAssertTrue(plist.contains("<string>--idle-timeout</string>"))
        XCTAssertTrue(plist.contains("<string>0</string>"))
    }

    func testRenderEscapesSpecialCharacters() {
        let plist = LaunchAgent.render(executablePath: "/opt/a&b/msl")
        XCTAssertTrue(plist.contains("/opt/a&amp;b/msl"))
        XCTAssertFalse(plist.contains("/opt/a&b/msl"))
    }

    func testPlistPathIsUnderLaunchAgents() {
        let path = LaunchAgent.plistPath(homeDirectory: "/Users/x")
        XCTAssertEqual(path, "/Users/x/Library/LaunchAgents/dev.msl.daemon.plist")
    }
}
