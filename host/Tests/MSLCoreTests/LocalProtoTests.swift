import Foundation
import XCTest

@testable import MSLCore

final class LocalRequestRoundTripTests: XCTestCase {
    private func roundTrip(_ request: LocalRequest) throws -> LocalRequest {
        return try LocalRequest.decode(try request.encoded())
    }

    func testControlOpsRoundTrip() throws {
        let cases: [LocalRequest] = [
            .status,
            .up(name: "ubuntu"),
            .up(name: nil),
            .down(name: "ubuntu", all: false, timeoutMs: 15000),
            .down(name: nil, all: true, timeoutMs: nil),
            .attach(sessionID: 7, token: "deadbeef"),
            .resize(sessionID: 7, rows: 30, cols: 100),
            .signal(sessionID: 7, signal: 2),
            .wait(sessionID: 9),
            .authStatus(name: "ubuntu"),
            .authStatus(name: nil),
            .shutdown,
        ]
        for request in cases {
            XCTAssertEqual(try roundTrip(request), request)
        }
    }

    func testShellRoundTripWithAllFields() throws {
        let req = ShellRequest(
            name: "ubuntu", argv: ["/bin/bash", "-l"], env: ["TERM": "xterm-256color"],
            rows: 40, cols: 120, cwd: "/mnt/mac/dev")
        XCTAssertEqual(try roundTrip(.shell(req)), .shell(req))
    }

    func testShellRoundTripWithDefaults() throws {
        let req = ShellRequest(name: nil, argv: nil, env: nil, rows: 40, cols: 120, cwd: nil)
        XCTAssertEqual(try roundTrip(.shell(req)), .shell(req))
    }

    func testAttachUsesSnakeCaseSessionKey() throws {
        let data = try LocalRequest.attach(sessionID: 5, token: "ab").encoded()
        let json = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"session_id\""), json)
        XCTAssertFalse(json.contains("sessionID"), json)
    }

    func testUnknownOpRejected() {
        let bytes = Data(#"{"op":"frobnicate"}"#.utf8)
        XCTAssertThrowsError(try LocalRequest.decode(bytes))
    }
}

final class LocalReplyRoundTripTests: XCTestCase {
    func testStatusReplyRoundTrip() throws {
        let status = StatusData(
            vm: "running",
            distros: [
                DistroStatus(name: "ubuntu", state: "running", sessions: 2),
                DistroStatus(name: "debian", state: "stopped", sessions: 0),
            ],
            idleTimeoutS: 60)
        let reply = try LocalResponse<StatusData>.decode(try LocalReply.ok(status))
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.data, status)
        XCTAssertNil(reply.error)
    }

    func testShellReplyRoundTrip() throws {
        let data = ShellData(sessionID: 12, token: "cafef00d")
        let reply = try LocalResponse<ShellData>.decode(try LocalReply.ok(data))
        XCTAssertEqual(reply.data, data)
    }

    func testWaitReplyRoundTrip() throws {
        let data = LocalWaitData(done: true, exitCode: 42)
        let reply = try LocalResponse<LocalWaitData>.decode(try LocalReply.ok(data))
        XCTAssertEqual(reply.data, data)
    }

    func testErrorReplyDecodes() throws {
        let reply = try LocalResponse<LocalEmpty>.decode(try LocalReply.error("boom"))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "boom")
        XCTAssertNil(reply.data)
    }

    func testStatusUsesSnakeCaseIdleKey() throws {
        let status = StatusData(vm: "stopped", distros: [], idleTimeoutS: 60)
        let json = String(bytes: try LocalReply.ok(status), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"idle_timeout_s\""), json)
    }

    func testAuthStatusReplyRoundTrip() throws {
        let status = AuthStatusData(
            distro: "ubuntu", sshAgent: true, secrets: false,
            sshAgentDetail: "host SSH_AUTH_SOCK is unavailable",
            secretsDetail: "disabled by policy")
        let reply = try LocalResponse<AuthStatusData>.decode(try LocalReply.ok(status))
        XCTAssertEqual(reply.data, status)
        let json = String(bytes: try LocalReply.ok(status), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"ssh_agent\""), json)
        XCTAssertTrue(json.contains("\"ssh_agent_detail\""), json)
        XCTAssertTrue(json.contains("\"secrets_bus\""), json)
    }
}
