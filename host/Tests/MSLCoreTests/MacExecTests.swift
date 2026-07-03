import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class MacExecTranslateTests: XCTestCase {
    func testExactMacPrefixMapsToShareRoot() {
        XCTAssertEqual(
            MacExec.translateCwd("/mnt/mac", shareRoot: "/Users/x", home: "/Users/x"), "/Users/x")
    }

    func testMacSubpathMapsUnderShareRoot() {
        XCTAssertEqual(
            MacExec.translateCwd("/mnt/mac/Dev/msl", shareRoot: "/Users/x", home: "/Users/x"),
            "/Users/x/Dev/msl")
    }

    func testNonMacPathFallsBackToHome() {
        XCTAssertEqual(
            MacExec.translateCwd("/var/log", shareRoot: "/Users/x", home: "/Users/x"), "/Users/x")
    }

    func testNoShareAlwaysHome() {
        XCTAssertEqual(
            MacExec.translateCwd("/mnt/mac/Dev", shareRoot: nil, home: "/Users/x"), "/Users/x")
    }
}

final class MacExecSpawnTests: XCTestCase {
    func testPipeSpawnStreamsStdoutAndExitsZero() throws {
        let proc = try MacExec.spawn(
            argv: ["/bin/echo", "spawned-hello"], cwd: "/tmp", extraEnv: [:], tty: nil)
        guard case .pipes(let stdin, let stdout, let stderr) = proc.stdio else {
            return XCTFail("expected pipe stdio")
        }
        let text = Self.drain(stdout)
        _ = Darwin.close(stdin)
        _ = Darwin.close(stdout)
        _ = Darwin.close(stderr)
        XCTAssertEqual(MacExec.wait(pid: proc.pid), 0)
        XCTAssertTrue(text.contains("spawned-hello"), text)
    }

    func testTtySpawnRoutesOutputThroughPTY() throws {
        let proc = try MacExec.spawn(
            argv: ["/bin/echo", "tty-hello"], cwd: "/tmp", extraEnv: [:],
            tty: TTYRequest(rows: 24, cols: 80))
        guard case .pty(let primary) = proc.stdio else { return XCTFail("expected pty stdio") }
        let text = Self.drain(primary)
        _ = Darwin.close(primary)
        XCTAssertEqual(MacExec.wait(pid: proc.pid), 0)
        XCTAssertTrue(text.contains("tty-hello"), text)
    }

    func testNonzeroExitPropagates() throws {
        let proc = try MacExec.spawn(
            argv: ["/bin/sh", "-c", "exit 3"], cwd: "/tmp", extraEnv: [:], tty: nil)
        Self.closePipes(proc)
        XCTAssertEqual(MacExec.wait(pid: proc.pid), 3)
    }

    func testSignalDeathMapsTo128PlusSignal() throws {
        let proc = try MacExec.spawn(
            argv: ["/bin/sh", "-c", "kill -TERM $$"], cwd: "/tmp", extraEnv: [:], tty: nil)
        Self.closePipes(proc)
        XCTAssertEqual(MacExec.wait(pid: proc.pid), 128 + SIGTERM)
    }

    func testEmptyArgvIsRejected() {
        XCTAssertThrowsError(
            try MacExec.spawn(argv: [], cwd: "/tmp", extraEnv: [:], tty: nil))
    }

    /// Read `fd` to EOF (bounded) and decode as UTF-8 for substring assertions.
    private static func drain(_ fd: Int32) -> String {
        var out = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<4096 {  // bounded: at most 16 MiB of child output
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                out.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private static func closePipes(_ proc: MacProcess) {
        guard case .pipes(let stdin, let stdout, let stderr) = proc.stdio else { return }
        _ = Darwin.close(stdin)
        _ = Darwin.close(stdout)
        _ = Darwin.close(stderr)
    }
}

final class MacExecTraversalTests: XCTestCase {
    func testDotDotRemainderFallsBackToHome() {
        let mapped = MacExec.translateCwd(
            "/mnt/mac/../../etc", shareRoot: "/Users/u", home: "/Users/u")
        XCTAssertEqual(mapped, "/Users/u")
    }

    func testDotDotAtEndFallsBackToHome() {
        let mapped = MacExec.translateCwd(
            "/mnt/mac/Dev/..", shareRoot: "/Users/u", home: "/Users/u")
        XCTAssertEqual(mapped, "/Users/u")
    }

    func testDotDotLookalikeComponentIsKept() {
        let mapped = MacExec.translateCwd(
            "/mnt/mac/a..b", shareRoot: "/Users/u", home: "/Users/u")
        XCTAssertEqual(mapped, "/Users/u/a..b")
    }
}
