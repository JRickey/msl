import Foundation
import XCTest

@testable import MSLCore

final class InteropProtoTests: XCTestCase {
    func testInteropPortAndTags() {
        XCTAssertEqual(Proto.interopPort, 5010)
        XCTAssertEqual(InteropTag.stdin.rawValue, 0)
        XCTAssertEqual(InteropTag.stdout.rawValue, 1)
        XCTAssertEqual(InteropTag.stderr.rawValue, 2)
        XCTAssertEqual(InteropTag.exit.rawValue, 3)
        XCTAssertEqual(InteropTag.winch.rawValue, 4)
        XCTAssertEqual(InteropTag.stdinEOF.rawValue, 5)
    }

    func testHelloDecodesFullObject() throws {
        let json = Data(
            (#"{"v":1,"op":"mac_exec","argv":["open","."],"cwd":"/mnt/mac/Dev","#
                + #""env":{"TERM":"xterm-256color"},"tty":true,"rows":40,"cols":120}"#).utf8)
        let hello = try MacExecHello.decode(json)
        XCTAssertEqual(hello.argv, ["open", "."])
        XCTAssertEqual(hello.cwd, "/mnt/mac/Dev")
        XCTAssertEqual(hello.env["TERM"], "xterm-256color")
        XCTAssertTrue(hello.tty)
        XCTAssertEqual(hello.rows, 40)
        XCTAssertEqual(hello.cols, 120)
    }

    func testHelloDefaultsAbsentFields() throws {
        let json = Data(#"{"v":1,"op":"mac_exec","argv":["ls"],"cwd":"/tmp"}"#.utf8)
        let hello = try MacExecHello.decode(json)
        XCTAssertFalse(hello.tty)
        XCTAssertEqual(hello.rows, 0)
        XCTAssertEqual(hello.cols, 0)
        XCTAssertTrue(hello.env.isEmpty)
    }

    func testHelloDecodesBinfmtTrue() throws {
        let json = Data(
            #"{"v":1,"op":"mac_exec","argv":["/mnt/mac/Dev/tool"],"cwd":"/","binfmt":true}"#.utf8)
        let hello = try MacExecHello.decode(json)
        XCTAssertTrue(hello.binfmt)
    }

    func testHelloBinfmtDefaultsFalseWhenAbsent() throws {
        let json = Data(#"{"v":1,"op":"mac_exec","argv":["ls"],"cwd":"/tmp"}"#.utf8)
        let hello = try MacExecHello.decode(json)
        XCTAssertFalse(hello.binfmt)
    }

    func testLegacyHelloWithoutBinfmtStillValidates() throws {
        let json = Data(
            #"{"v":1,"op":"mac_exec","argv":["open","."],"cwd":"/mnt/mac/Dev","tty":false}"#.utf8)
        let hello = try MacExecHello.decode(json)
        XCTAssertFalse(hello.binfmt)
        XCTAssertEqual(hello.argv, ["open", "."])
    }

    func testValidateRejectsBadVersion() {
        let hello = try? JSONDecoder().decode(
            MacExecHello.self, from: Data(#"{"v":2,"op":"mac_exec","argv":["ls"]}"#.utf8))
        XCTAssertThrowsError(try XCTUnwrap(hello).validate())
    }

    func testValidateRejectsWrongOp() {
        let hello = try? JSONDecoder().decode(
            MacExecHello.self, from: Data(#"{"v":1,"op":"nope","argv":["ls"]}"#.utf8))
        XCTAssertThrowsError(try XCTUnwrap(hello).validate())
    }

    func testValidateRejectsEmptyArgv() {
        let hello = try? JSONDecoder().decode(
            MacExecHello.self, from: Data(#"{"v":1,"op":"mac_exec","argv":[]}"#.utf8))
        XCTAssertThrowsError(try XCTUnwrap(hello).validate())
    }

    func testDecodeRejectsEmptyFrame() {
        XCTAssertThrowsError(try MacExecHello.decode(Data()))
    }

    func testReplyOkEncodes() throws {
        let json = try XCTUnwrap(String(bytes: InteropReply.ok().encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"ok\":true"), json)
    }

    func testReplyFailureCarriesError() throws {
        let data = try InteropReply.failure("too many interop sessions").encoded()
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"ok\":false"), json)
        XCTAssertTrue(json.contains("too many interop sessions"), json)
    }

    func testExitEncodesCode() throws {
        let json = try XCTUnwrap(String(bytes: InteropExit(code: 7).encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"code\":7"), json)
    }

    func testResizeDecodes() throws {
        let resize = try JSONDecoder().decode(
            InteropResize.self, from: Data(#"{"rows":50,"cols":200}"#.utf8))
        XCTAssertEqual(resize.rows, 50)
        XCTAssertEqual(resize.cols, 200)
    }
}

final class InteropHelloBoundTests: XCTestCase {
    func testOversizedHelloIsRejected() {
        let padding = String(repeating: "x", count: MacExecHello.maxHelloBytes)
        let json = #"{"v":1,"op":"mac_exec","argv":["true"],"cwd":"/"# + padding + #""}"#
        XCTAssertThrowsError(try MacExecHello.decode(Data(json.utf8)))
    }
}

final class InteropResolveArgvTests: XCTestCase {
    private func decodeHello(argv: [String], binfmt: Bool) throws -> MacExecHello {
        let quoted = argv.map { "\"\($0)\"" }.joined(separator: ",")
        let json =
            "{\"v\":1,\"op\":\"mac_exec\",\"argv\":[\(quoted)],\"cwd\":\"/\","
            + "\"binfmt\":\(binfmt)}"
        return try MacExecHello.decode(Data(json.utf8))
    }

    func testExplicitModePassesArgvThrough() throws {
        let hello = try decodeHello(argv: ["open", "."], binfmt: false)
        XCTAssertEqual(try DaemonCore.resolveArgv(hello, shareRoot: "/Users/x"), ["open", "."])
    }

    func testBinfmtRewritesExecutableTarget() throws {
        let dir = NSTemporaryDirectory() + "msl-binfmt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let exe = dir + "/tool"
        XCTAssertTrue(FileManager.default.createFile(atPath: exe, contents: Data("x".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe)
        let hello = try decodeHello(argv: ["/mnt/mac/tool", "arg"], binfmt: true)
        XCTAssertEqual(try DaemonCore.resolveArgv(hello, shareRoot: dir), [exe, "arg"])
    }

    func testBinfmtRejectsNonExecutableTarget() throws {
        let dir = NSTemporaryDirectory() + "msl-binfmt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let hello = try decodeHello(argv: ["/mnt/mac/missing"], binfmt: true)
        XCTAssertThrowsError(try DaemonCore.resolveArgv(hello, shareRoot: dir))
    }

    func testBinfmtRejectsOutsideShare() throws {
        let hello = try decodeHello(argv: ["/usr/bin/true"], binfmt: true)
        XCTAssertThrowsError(try DaemonCore.resolveArgv(hello, shareRoot: "/Users/x"))
    }
}
