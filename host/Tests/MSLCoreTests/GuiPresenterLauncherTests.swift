import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class GuiPresenterLauncherTests: XCTestCase {
    func testExecutableResolvesNextToTheHostBinary() {
        XCTAssertEqual(
            GuiPresenterLauncher.executablePath(selfPath: "/opt/msl.app/Contents/MacOS/msl"),
            "/opt/msl.app/Contents/MacOS/msl-presenter")
        XCTAssertEqual(
            GuiPresenterLauncher.executablePath(selfPath: "/x/.build/release/msl"),
            "/x/.build/release/msl-presenter")
    }

    func testTokenDescriptorIsAboveStdio() {
        // The token fd never collides with 0/1/2, so CLOEXEC_DEFAULT can keep only
        // stdio plus this descriptor across the exec.
        XCTAssertGreaterThanOrEqual(GuiPresenterLauncher.tokenFD, 3)
    }

    /// The daemon's write half of the token handoff: a token written into the pipe
    /// arrives byte-for-byte on the read end, and closing the write end signals EOF
    /// (which is how the presenter knows the token is complete).
    func testTokenHandoffOverPipeRoundTrips() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        defer { _ = Darwin.close(readFD) }
        let token = String(repeating: "d", count: LocalProto.tokenHexLength)
        try GuiPresenterLauncher.writeToken(token, to: writeFD)
        XCTAssertEqual(Darwin.close(writeFD), 0)
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(readFD, base, 256)
        }
        XCTAssertGreaterThan(count, 0)
        let received = String(bytes: buffer[0..<max(count, 0)], encoding: .utf8) ?? ""
        XCTAssertEqual(received, token)
        XCTAssertEqual(received.count, LocalProto.tokenHexLength)
    }
}
