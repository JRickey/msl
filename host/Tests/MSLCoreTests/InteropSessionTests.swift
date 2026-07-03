import Darwin
import Foundation
import XCTest

@testable import MSLCore

/// Drives `InteropSession` over a socketpair: one end is the session's fd, the
/// other stands in for the guest shim. The spawner is the real `MacExec`.
final class InteropSessionTests: XCTestCase {
    private struct ReplyBody: Decodable {
        let ok: Bool
        let error: String?
    }
    private struct ExitBody: Decodable {
        let code: Int32
    }

    func testPipeSessionRepliesStreamsAndExits() throws {
        let client = try startSession(admitted: true)
        defer { _ = Darwin.close(client) }
        try Self.sendHello(
            client, argv: ["/bin/echo", "interop-hello"], cwd: "/tmp", tty: false)
        XCTAssertTrue(try Self.readReply(client).ok)
        let result = try Self.readUntilExit(client)
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("interop-hello"), result.stdout)
    }

    func testTtySessionStreamsOutput() throws {
        let client = try startSession(admitted: true)
        defer { _ = Darwin.close(client) }
        try Self.sendHello(client, argv: ["/bin/echo", "pty-line"], cwd: "/tmp", tty: true)
        XCTAssertTrue(try Self.readReply(client).ok)
        let result = try Self.readUntilExit(client)
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("pty-line"), result.stdout)
    }

    func testStdinIsForwardedToChild() throws {
        let client = try startSession(admitted: true)
        defer { _ = Darwin.close(client) }
        try Self.sendHello(client, argv: ["/bin/cat"], cwd: "/tmp", tty: false)
        XCTAssertTrue(try Self.readReply(client).ok)
        XCTAssertTrue(Self.sendFrame(client, tag: .stdin, data: Array("echoed\n".utf8)))
        XCTAssertTrue(Self.sendFrame(client, tag: .stdinEOF, data: []))
        let result = try Self.readUntilExit(client)
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("echoed"), result.stdout)
    }

    func testOverCapSessionIsRejected() throws {
        let client = try startSession(admitted: false)
        defer { _ = Darwin.close(client) }
        let reply = try Self.readReply(client)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "too many interop sessions")
    }

    func testBadHelloIsRejected() throws {
        let client = try startSession(admitted: true)
        defer { _ = Darwin.close(client) }
        XCTAssertTrue(Self.sendFrame(client, tag: .stdin, data: Array(#"{"v":2}"#.utf8)))
        let reply = try Self.readReply(client)
        XCTAssertFalse(reply.ok)
    }

    private func startSession(admitted: Bool) throws -> Int32 {
        let pair = try Self.socketPair()
        try Self.setTimeout(pair.client, seconds: 5)
        let spawner: @Sendable (MacExecHello) throws -> MacProcess = { hello in
            let tty = hello.tty ? TTYRequest(rows: hello.rows, cols: hello.cols) : nil
            return try MacExec.spawn(argv: hello.argv, cwd: hello.cwd, extraEnv: [:], tty: tty)
        }
        let session = InteropSession(
            fd: pair.session, admitted: admitted, spawner: spawner, logger: { _ in },
            beginActivity: {}, endActivity: {})
        Thread.detachNewThread { session.run() }
        return pair.client
    }

    // MARK: - wire helpers

    private static func sendHello(_ fd: Int32, argv: [String], cwd: String, tty: Bool) throws {
        let object: [String: Any] = [
            "v": 1, "op": "mac_exec", "argv": argv, "cwd": cwd, "tty": tty,
            "rows": tty ? 24 : 0, "cols": tty ? 80 : 0, "env": [String: String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(writeFrame(fd, payload: [UInt8](data)))
    }

    private static func readReply(_ fd: Int32) throws -> ReplyBody {
        let payload = try XCTUnwrap(readFrame(fd), "reply frame missing")
        return try JSONDecoder().decode(ReplyBody.self, from: Data(payload))
    }

    private static func readUntilExit(_ fd: Int32) throws -> (code: Int32, stdout: String) {
        var out = [UInt8]()
        for _ in 0..<1024 {  // bounded: at most 1024 data frames per test child
            guard let payload = readFrame(fd), let tag = payload.first else {
                throw MSLError.io("stream ended before exit frame")
            }
            let body = Array(payload.dropFirst())
            if tag == InteropTag.stdout.rawValue { out.append(contentsOf: body) }
            if tag == InteropTag.exit.rawValue {
                let exit = try JSONDecoder().decode(ExitBody.self, from: Data(body))
                return (exit.code, String(bytes: out, encoding: .utf8) ?? "")
            }
        }
        throw MSLError.io("exit frame never arrived")
    }

    private static func sendFrame(_ fd: Int32, tag: InteropTag, data: [UInt8]) -> Bool {
        return writeFrame(fd, payload: [tag.rawValue] + data)
    }

    private static func writeFrame(_ fd: Int32, payload: [UInt8]) -> Bool {
        let len = payload.count
        var frame: [UInt8] = [
            UInt8((len >> 24) & 0xff), UInt8((len >> 16) & 0xff),
            UInt8((len >> 8) & 0xff), UInt8(len & 0xff),
        ]
        frame.append(contentsOf: payload)
        var sent = 0
        for _ in 0..<(frame.count + 64) {  // bounded: each write advances >=1 byte
            if sent == frame.count { return true }
            let chunk = frame.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), frame.count - sent)
            }
            if chunk > 0 {
                sent += chunk
            } else if chunk < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return false
    }

    private static func readFrame(_ fd: Int32) -> [UInt8]? {
        guard let header = readExactly(fd, 4) else { return nil }
        let len =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8)
            | Int(header[3])
        guard len >= 0, len <= 4 * 1024 * 1024 else { return nil }
        return readExactly(fd, len)
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        for _ in 0..<(count + 64) {  // bounded: each read advances >=1 byte
            if got == count { return buffer }
            let chunk = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if chunk > 0 {
                got += chunk
            } else if chunk < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return nil
    }

    private static func socketPair() throws -> (session: Int32, client: Int32) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return socketpair(AF_UNIX, SOCK_STREAM, 0, base)
        }
        guard rc == 0 else { throw MSLError.io("socketpair failed errno=\(errno)") }
        return (session: fds[0], client: fds[1])
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) throws {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        let rc = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard rc == 0 else { throw MSLError.io("setsockopt SO_RCVTIMEO failed errno=\(errno)") }
    }
}
