import Darwin
import Foundation
import MSLFSWire
import XCTest

@testable import MSLCore

final class FSMountListenerTests: XCTestCase {
    func testRoutesAuthenticatesAndSplicesBidirectionally() throws {
        let table = FSMountTable()
        let rec = table.prepare(name: "ubuntu", mountpoint: "/tmp/msl/ubuntu", readonly: true)
        let guest = try makeSocketPair()
        let path = tempSocketPath()
        let listener = FSMountListener(
            socketPath: path, authenticator: FSStaticAuthenticator(admit: true), table: table,
            connectGuest: { _ in guest.daemonSide }, logger: { _ in })
        try listener.start()
        defer {
            listener.stop()
            _ = Darwin.close(guest.ourGuest)
        }

        let appex = try handshake(
            path: path, hello: FSHello(distro: "ubuntu", mountID: rec.mountID, nonce: rec.nonce))
        try writeAll(appex, Data("ping".utf8))
        XCTAssertEqual(try readExactly(guest.ourGuest, 4), Data("ping".utf8))
        try writeAll(guest.ourGuest, Data("pong".utf8))
        XCTAssertEqual(try readExactly(appex, 4), Data("pong".utf8))

        // Bounded splice shutdown: closing the appex end must make the guest side
        // observe EOF quickly, not hang. A read timeout guards the assertion.
        setReadTimeout(guest.ourGuest, seconds: 3)
        _ = Darwin.close(appex)
        var byte: UInt8 = 0
        let count = Darwin.read(guest.ourGuest, &byte, 1)
        XCTAssertEqual(count, 0, "guest must see bounded EOF after appex close")
    }

    func testRejectsUnauthenticatedPeer() throws {
        let table = FSMountTable()
        _ = table.prepare(name: "ubuntu", mountpoint: "/tmp/msl/ubuntu", readonly: true)
        let path = tempSocketPath()
        let listener = FSMountListener(
            socketPath: path, authenticator: FSStaticAuthenticator(admit: false), table: table,
            connectGuest: { _ in
                XCTFail("guest must not be reached"); return -1
            }, logger: { _ in })
        try listener.start()
        defer { listener.stop() }

        let framed = try dial(path)
        let reply = try FSControlReply.decode(try framed.receive())
        XCTAssertFalse(reply.ok)
        framed.close()
    }

    func testDeniesUnknownOrReplayedMount() throws {
        let table = FSMountTable()
        let rec = table.prepare(name: "ubuntu", mountpoint: "/tmp/msl/ubuntu", readonly: true)
        XCTAssertTrue(table.consumeNonce(distro: "ubuntu", mountID: rec.mountID, nonce: rec.nonce))
        let path = tempSocketPath()
        let listener = FSMountListener(
            socketPath: path, authenticator: FSStaticAuthenticator(admit: true), table: table,
            connectGuest: { _ in
                XCTFail("guest must not be reached"); return -1
            }, logger: { _ in })
        try listener.start()
        defer { listener.stop() }

        // The nonce was already consumed above, so this route (a replay) is denied.
        let framed = try dial(path)
        try framed.send(
            try FSHello(distro: "ubuntu", mountID: rec.mountID, nonce: rec.nonce).encoded())
        let reply = try FSControlReply.decode(try framed.receive())
        XCTAssertFalse(reply.ok)
        framed.close()
    }

    // MARK: - Helpers

    private struct SocketPair {
        let daemonSide: Int32
        let ourGuest: Int32
    }

    private func makeSocketPair() throws -> SocketPair {
        var fds = [Int32](repeating: -1, count: 2)
        let rc = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard rc == 0 else { throw MSLError.io("socketpair failed: errno=\(errno)") }
        return SocketPair(daemonSide: fds[0], ourGuest: fds[1])
    }

    private func tempSocketPath() -> String {
        return "/tmp/msl-fslisten-\(UUID().uuidString.prefix(8)).sock"
    }

    private func dial(_ path: String) throws -> VsockClient {
        let fd = try LocalSocket.dial(path: path)
        let framed = try VsockClient(fileDescriptor: fd)
        try framed.setReceiveTimeout(seconds: 5)
        return framed
    }

    /// Send the hello, read the control reply, and return the detached raw fd for
    /// the splice phase (mirrors what the FSKit appex does after routing).
    private func handshake(path: String, hello: FSHello) throws -> Int32 {
        let framed = try dial(path)
        try framed.send(try hello.encoded())
        let reply = try FSControlReply.decode(try framed.receive())
        XCTAssertTrue(reply.ok, reply.error ?? "route failed")
        return framed.detachDescriptor()
    }

    private func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        let bytes = [UInt8](data)
        var sent = 0
        for _ in 0..<(bytes.count + 8) {  // bounded: each write advances the cursor
            if sent == bytes.count { return }
            let count = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
            }
            if count > 0 { sent += count } else { throw MSLError.io("write failed") }
        }
        throw MSLError.io("write did not complete")
    }

    private func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        for _ in 0..<(count + 8) {  // bounded: each read advances the cursor
            if got == count { return Data(buffer) }
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if read > 0 { got += read } else { throw MSLError.io("read short: \(got)/\(count)") }
        }
        throw MSLError.io("read did not complete")
    }
}
