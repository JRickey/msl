import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class PortForwarderDiffTests: XCTestCase {
    private func diff(
        current: [UInt16], desired: [UInt16], failed: [UInt16] = [], cap: Int = 64
    ) -> (open: [UInt16], close: [UInt16]) {
        return PortForwarder.diff(
            current: Set(current), desired: Set(desired), failed: Set(failed), cap: cap)
    }

    func testAddNewPorts() {
        let plan = diff(current: [], desired: [22, 80])
        XCTAssertEqual(plan.open, [22, 80])
        XCTAssertEqual(plan.close, [])
    }

    func testRemoveVanishedPorts() {
        let plan = diff(current: [22, 80], desired: [22])
        XCTAssertEqual(plan.open, [])
        XCTAssertEqual(plan.close, [80])
    }

    func testAddAndRemoveTogether() {
        let plan = diff(current: [22, 80], desired: [22, 443])
        XCTAssertEqual(plan.open, [443])
        XCTAssertEqual(plan.close, [80])
    }

    func testFailedPortsExcludedFromOpen() {
        let plan = diff(current: [], desired: [53, 80], failed: [53])
        XCTAssertEqual(plan.open, [80])
        XCTAssertEqual(plan.close, [])
    }

    func testCapLimitsNewOpens() {
        let plan = diff(current: [], desired: [1, 2, 3, 4, 5], cap: 3)
        XCTAssertEqual(plan.open, [1, 2, 3])
        XCTAssertEqual(plan.close, [])
    }

    func testCapCountsRetainedButNotClosable() {
        let retained = diff(current: [1, 2], desired: [1, 2, 3, 4], cap: 3)
        XCTAssertEqual(retained.open, [3])
        let closable = diff(current: [1, 2, 3], desired: [4, 5], cap: 3)
        XCTAssertEqual(closable.open, [4, 5])
        XCTAssertEqual(closable.close, [1, 2, 3])
    }
}

/// End-to-end check: a mirrored listener accepts a loopback connection, invokes
/// the injected guest connect, and relays bytes in both directions.
final class PortForwarderLiveTests: XCTestCase {
    private final class PeerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        func store(_ value: Int32) {
            lock.lock()
            fd = value
            lock.unlock()
        }
        func take() -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            return fd
        }
    }

    func testMirrorsAndRelaysBothDirections() throws {
        let port = try Self.freePort()
        let peers = PeerBox()
        let forwarder = PortForwarder(connectGuest: { _ in
            let pair = try Self.makeSocketPair()
            peers.store(pair.1)
            return pair.0
        })
        forwarder.start()
        defer { forwarder.stop() }
        forwarder.update(ports: [port])
        try Self.waitUntil { forwarder.mirroredPorts().contains(port) }

        let client = try Self.dialLoopback(port: port)
        defer { _ = Darwin.close(client) }
        try Self.waitUntil { peers.take() >= 0 }
        let peer = peers.take()
        defer { _ = Darwin.close(peer) }

        XCTAssertEqual(try Self.roundTrip(write: "ping", to: client, readOn: peer), "ping")
        XCTAssertEqual(try Self.roundTrip(write: "pong", to: peer, readOn: client), "pong")
    }

    /// After stop(), update() must open nothing: its plan short-circuits on the
    /// cleared `running` flag, and applyOpen bails rather than leaking a listener.
    /// (The exact mid-applyOpen stop interleaving is not deterministically
    /// reachable through the public API, so this covers the observable outcome.)
    func testUpdateAfterStopOpensNothing() throws {
        let port = try Self.freePort()
        let forwarder = PortForwarder(connectGuest: { _ in
            throw MSLError.io("guest connect should not be reached")
        })
        forwarder.start()
        forwarder.stop()
        forwarder.update(ports: [port])
        XCTAssertTrue(forwarder.mirroredPorts().isEmpty)
        XCTAssertNoThrow(try Self.assertPortFree(port))
    }

    private static func assertPortFree(_ port: UInt16) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MSLError.io("socket failed") }
        defer { _ = Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw MSLError.io("port \(port) still bound; leaked") }
    }

    private static func roundTrip(
        write text: String, to writeFD: Int32, readOn readFD: Int32
    ) throws -> String {
        let bytes = Array(text.utf8)
        let sent = bytes.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        XCTAssertEqual(sent, bytes.count)
        var buffer = [UInt8](repeating: 0, count: bytes.count)
        let got = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        guard got == bytes.count, let echoed = String(bytes: buffer, encoding: .utf8) else {
            throw MSLError.io("short or non-utf8 read (\(got))")
        }
        return echoed
    }

    private static func waitUntil(_ predicate: () -> Bool) throws {
        for _ in 0..<200 {  // bounded: up to ~2 s
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw MSLError.timedOut("condition not met")
    }

    private static func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return socketpair(AF_UNIX, SOCK_STREAM, 0, base)
        }
        guard rc == 0 else { throw MSLError.io("socketpair failed") }
        return (fds[0], fds[1])
    }

    private static func freePort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MSLError.io("socket failed") }
        defer { _ = Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw MSLError.io("bind failed") }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &out) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { throw MSLError.io("getsockname failed") }
        return UInt16(bigEndian: out.sin_port)
    }

    private static func dialLoopback(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MSLError.io("socket failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let rc = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            _ = Darwin.close(fd)
            throw MSLError.io("connect failed errno=\(errno)")
        }
        return fd
    }
}
