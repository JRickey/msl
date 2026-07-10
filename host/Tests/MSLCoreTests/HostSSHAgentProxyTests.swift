import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class HostSSHAgentProxyTests: XCTestCase {
    func testAllowlistForwardsReadOnlyAgentMessages() throws {
        XCTAssertNoThrow(try HostSSHAgentProxy.validateAllowed(Data([11]), forwarding: false))
        XCTAssertNoThrow(try HostSSHAgentProxy.validateAllowed(Data([13, 0]), forwarding: false))
    }

    /// add identity, remove identity, remove all, lock, unlock, add smartcard,
    /// remove smartcard: guests may not mutate the Mac user's agent.
    func testAllowlistRejectsMutationMessages() {
        for type: UInt8 in [17, 18, 19, 22, 23, 25, 26] {
            XCTAssertThrowsError(
                try HostSSHAgentProxy.validateAllowed(Data([type]), forwarding: false)
            ) { error in
                XCTAssertEqual(
                    error as? AuthProxyError,
                    .denied("ssh-agent request \(type) is not forwarded"))
            }
        }
    }

    func testExtensionQueryWithoutSessionBindIsForwarded() throws {
        let packet = Self.extensionPacket(name: "query", body: [])
        XCTAssertNoThrow(try HostSSHAgentProxy.validateAllowed(packet, forwarding: false))
    }

    func testTruncatedExtensionIsRejected() {
        XCTAssertThrowsError(
            try HostSSHAgentProxy.validateAllowed(Data([27, 0]), forwarding: false)
        ) { error in
            XCTAssertEqual(error as? AuthProxyError, .badRequest("bad ssh-agent extension name"))
        }
    }

    func testSessionBindWithoutForwardingFlagIsAllowedUnderOffPolicy() throws {
        let packet = Self.sessionBind(forwarding: false)
        XCTAssertNoThrow(try HostSSHAgentProxy.validateAllowed(packet, forwarding: false))
    }

    func testSessionBindDeclaringForwardingIsRejectedUnderOffPolicy() {
        let packet = Self.sessionBind(forwarding: true)
        XCTAssertThrowsError(
            try HostSSHAgentProxy.validateAllowed(packet, forwarding: false)
        ) { error in
            XCTAssertEqual(
                error as? AuthProxyError, .denied("ssh-agent forwarding is disabled by policy"))
        }
    }

    func testSessionBindDeclaringForwardingIsAllowedUnderOnPolicy() throws {
        let packet = Self.sessionBind(forwarding: true)
        XCTAssertNoThrow(try HostSSHAgentProxy.validateAllowed(packet, forwarding: true))
    }

    func testTruncatedSessionBindIsRejected() {
        var packet = Self.sessionBind(forwarding: true)
        packet.removeLast()
        XCTAssertThrowsError(
            try HostSSHAgentProxy.validateAllowed(packet, forwarding: true)
        ) { error in
            XCTAssertEqual(error as? AuthProxyError, .badRequest("bad session-bind extension"))
        }
    }

    func testForwardRejectsEmptyAndOversizedPackets() {
        let proxy = HostSSHAgentProxy(socketPath: "/tmp/fake-agent") { _ in -1 }
        XCTAssertThrowsError(try proxy.forward(packet: Data(), forwarding: false)) { error in
            XCTAssertEqual(error as? AuthProxyError, .badRequest("empty ssh-agent packet"))
        }
        let big = Data([11]) + Data(repeating: 0, count: HostSSHAgentProxy.maxPacket)
        XCTAssertThrowsError(try proxy.forward(packet: big, forwarding: false)) { error in
            XCTAssertEqual(error as? AuthProxyError, .tooLarge)
        }
    }

    func testForwardWithoutSocketPathIsUnavailable() {
        let proxy = HostSSHAgentProxy(socketPath: nil)
        XCTAssertFalse(proxy.available)
        XCTAssertThrowsError(try proxy.forward(packet: Data([11]), forwarding: false)) { error in
            XCTAssertEqual(error as? AuthProxyError, .unavailable)
        }
    }

    func testForwardSurfacesDialFailure() {
        let proxy = HostSSHAgentProxy(socketPath: "/tmp/missing-agent") { _ in
            throw MSLError.io("connect failed")
        }
        XCTAssertThrowsError(try proxy.forward(packet: Data([11]), forwarding: false))
    }

    func testForwardWritesFrameAndReturnsAgentReply() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let clientFD = fds[0]
        let serverFD = fds[1]
        let done = expectation(description: "fake ssh-agent handled request")
        let reply = Data([12, 0, 0, 0, 0])

        Thread {
            defer {
                _ = Darwin.close(serverFD)
                done.fulfill()
            }
            do {
                let request = try Self.readFrame(fd: serverFD)
                XCTAssertEqual(request, Data([11]))
                try Self.writeFrame(reply, fd: serverFD)
            } catch {
                XCTFail("fake ssh-agent failed: \(error)")
            }
        }.start()

        let proxy = HostSSHAgentProxy(socketPath: "/tmp/fake-agent") { _ in clientFD }
        XCTAssertEqual(try proxy.forward(packet: Data([11]), forwarding: false), reply)
        wait(for: [done], timeout: 1)
    }

    /// A live agent that accepts and never replies must fail, not hang.
    func testForwardTimesOutAgainstASilentAgent() {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { _ = Darwin.close(fds[1]) }
        let clientFD = fds[0]

        let proxy = HostSSHAgentProxy(socketPath: "/tmp/fake-agent", timeout: 0.2) { _ in clientFD }
        XCTAssertThrowsError(try proxy.forward(packet: Data([11]), forwarding: false)) { error in
            XCTAssertEqual(error as? AuthProxyError, .timedOut("ssh-agent read timed out"))
        }
    }

    private static func sessionBind(forwarding: Bool) -> Data {
        var body = string("host-key")
        body.append(contentsOf: string("session-id"))
        body.append(contentsOf: string("signature"))
        body.append(forwarding ? 1 : 0)
        return extensionPacket(name: HostSSHAgentProxy.sessionBind, body: body)
    }

    private static func extensionPacket(name: String, body: [UInt8]) -> Data {
        var packet: [UInt8] = [27]
        packet.append(contentsOf: string(name))
        packet.append(contentsOf: body)
        return Data(packet)
    }

    private static func string(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        let count = UInt32(bytes.count)
        var out: [UInt8] = [
            UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff), UInt8(count & 0xff),
        ]
        out.append(contentsOf: bytes)
        return out
    }

    private static func readFrame(fd: Int32) throws -> Data {
        let header = try readBytes(count: 4, fd: fd)
        let count =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8)
            | Int(header[3])
        return Data(try readBytes(count: count, fd: fd))
    }

    private static func writeFrame(_ packet: Data, fd: Int32) throws {
        let count = UInt32(packet.count)
        var bytes = [
            UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff), UInt8(count & 0xff),
        ]
        bytes.append(contentsOf: packet)
        try writeBytes(bytes, fd: fd)
    }

    private static func readBytes(count: Int, fd: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if got <= 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            offset += got
        }
        return bytes
    }

    private static func writeBytes(_ bytes: [UInt8], fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if sent <= 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            offset += sent
        }
    }
}
