import Darwin
import Foundation
import XCTest

@testable import MSLCore

private final class RelayCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false

    func markComplete() {
        lock.lock()
        complete = true
        lock.unlock()
    }

    func isComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }
}

final class ByteRelayTests: XCTestCase {
    private typealias Support = ByteRelayTestSupport

    func testBidirectionalPayloadFidelity() throws {
        let sockets = try Support.makeRelaySockets()
        defer { Support.closePeers(sockets) }
        let done = expectation(description: "relay stopped")
        let completion = RelayCompletion()
        Support.startRelay(sockets, done: done, completion: completion)
        let forward = Array("client to guest".utf8)
        let reverse = Array("guest to client".utf8)

        let received = try Support.transfer(sockets, forward: forward, reverse: reverse)

        XCTAssertEqual(received.atGuest, forward)
        XCTAssertEqual(received.atClient, reverse)
        Support.finishPeers(sockets)
        wait(for: [done], timeout: 1)
        XCTAssertTrue(completion.isComplete())
    }

    func testPayloadsLargerThanRelayBuffers() throws {
        let sockets = try Support.makeRelaySockets()
        defer { Support.closePeers(sockets) }
        let done = expectation(description: "large relay stopped")
        let completion = RelayCompletion()
        Support.startRelay(sockets, done: done, completion: completion)
        let forward = (0..<(256 * 1024)).map { UInt8($0 % 251) }
        let reverse = (0..<(192 * 1024)).map { UInt8(($0 * 7) % 253) }

        let received = try Support.transfer(sockets, forward: forward, reverse: reverse)

        XCTAssertEqual(received.atGuest, forward)
        XCTAssertEqual(received.atClient, reverse)
        Support.finishPeers(sockets)
        wait(for: [done], timeout: 2)
        XCTAssertTrue(completion.isComplete())
    }

    func testClientEOFCompletesWhileGuestWriteSideRemainsOpen() throws {
        let sockets = try Support.makeRelaySockets()
        defer { Support.closePeers(sockets) }
        let done = expectation(description: "client EOF stopped relay")
        let completion = RelayCompletion()
        Support.startRelay(sockets, done: done, completion: completion)
        let forward = (0..<(32 * 1024)).map { UInt8($0 % 239) }

        try Support.sendAll(forward, to: sockets.clientPeer)
        XCTAssertEqual(Darwin.shutdown(sockets.clientPeer, SHUT_WR), 0)
        let received = try Support.readUntilEOF(sockets.guestPeer, expected: forward.count)

        wait(for: [done], timeout: 1)
        XCTAssertEqual(received, forward)
        XCTAssertTrue(completion.isComplete())
    }

    func testGuestEOFDrainsBytesWhileClientWriteSideRemainsOpen() throws {
        let sockets = try Support.makeRelaySockets()
        defer { Support.closePeers(sockets) }
        let done = expectation(description: "guest EOF stopped relay")
        let completion = RelayCompletion()
        Support.startRelay(sockets, done: done, completion: completion)
        let reverse = (0..<(32 * 1024)).map { UInt8(($0 * 11) % 241) }

        try Support.sendAll(reverse, to: sockets.guestPeer)
        XCTAssertEqual(Darwin.shutdown(sockets.guestPeer, SHUT_WR), 0)
        let received = try Support.readUntilEOF(sockets.clientPeer, expected: reverse.count)

        wait(for: [done], timeout: 1)
        XCTAssertEqual(received, reverse)
        XCTAssertTrue(completion.isComplete())
    }

    func testPeerLossTearsDownPromptly() throws {
        var sockets = try Support.makeRelaySockets()
        let done = expectation(description: "lost-peer relay stopped")
        let completion = RelayCompletion()
        Support.startRelay(sockets, done: done, completion: completion)
        XCTAssertEqual(Darwin.close(sockets.clientPeer), 0)
        sockets.clientPeer = -1
        defer { Support.closePeers(sockets) }

        try Support.setNonblocking(sockets.guestPeer)
        try Support.waitForEOF(sockets.guestPeer)
        wait(for: [done], timeout: 1)

        XCTAssertTrue(completion.isComplete())
        XCTAssertEqual(Darwin.fcntl(sockets.clientRelay, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testRunOwnsAndClosesBothDescriptors() throws {
        let sockets = try Support.makeRelaySockets()
        defer { Support.closePeers(sockets) }
        let done = expectation(description: "relay descriptors closed")
        let completion = RelayCompletion()
        Support.startRelay(sockets, done: done, completion: completion)

        Support.finishPeers(sockets)
        wait(for: [done], timeout: 1)

        XCTAssertTrue(completion.isComplete())
        XCTAssertEqual(Darwin.fcntl(sockets.clientRelay, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertEqual(Darwin.fcntl(sockets.guestRelay, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

}

private enum ByteRelayTestSupport {
    struct RelaySockets {
        let clientRelay: Int32
        var clientPeer: Int32
        let guestRelay: Int32
        var guestPeer: Int32
    }

    static func makeRelaySockets() throws -> RelaySockets {
        let client = try socketPair()
        do {
            let guest = try socketPair()
            return RelaySockets(
                clientRelay: client.0, clientPeer: client.1,
                guestRelay: guest.0, guestPeer: guest.1)
        } catch {
            XCTAssertEqual(Darwin.close(client.0), 0)
            XCTAssertEqual(Darwin.close(client.1), 0)
            throw error
        }
    }

    private static func socketPair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, base)
        }
        guard result == 0 else { throw MSLError.io("socketpair failed: \(errno)") }
        XCTAssertGreaterThanOrEqual(descriptors[0], 0)
        XCTAssertGreaterThanOrEqual(descriptors[1], 0)
        return (descriptors[0], descriptors[1])
    }

    static func startRelay(
        _ sockets: RelaySockets, done: XCTestExpectation, completion: RelayCompletion
    ) {
        XCTAssertGreaterThanOrEqual(sockets.clientRelay, 0)
        XCTAssertGreaterThanOrEqual(sockets.guestRelay, 0)
        let relay = ByteRelay(clientFD: sockets.clientRelay, guestFD: sockets.guestRelay)
        Thread {
            relay.run()
            completion.markComplete()
            done.fulfill()
        }.start()
    }

    static func transfer(
        _ sockets: RelaySockets, forward: [UInt8], reverse: [UInt8]
    ) throws -> (atGuest: [UInt8], atClient: [UInt8]) {
        try setNonblocking(sockets.clientPeer)
        try setNonblocking(sockets.guestPeer)
        var forwardSent = 0
        var reverseSent = 0
        var atGuest: [UInt8] = []
        var atClient: [UInt8] = []
        for _ in 0..<20_000 {  // bounded peer-side progress attempts
            if atGuest.count == forward.count && atClient.count == reverse.count {
                return (atGuest, atClient)
            }
            var descriptors = peerPollDescriptors(
                sockets, forwardPending: forwardSent < forward.count,
                reversePending: reverseSent < reverse.count)
            let ready = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.poll(base, nfds_t(buffer.count), 10)
            }
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw MSLError.io("peer poll failed: \(errno)") }
            try writeAvailable(forward, offset: &forwardSent, descriptor: descriptors[0])
            try writeAvailable(reverse, offset: &reverseSent, descriptor: descriptors[1])
            try readAvailable(&atClient, expected: reverse.count, descriptor: descriptors[0])
            try readAvailable(&atGuest, expected: forward.count, descriptor: descriptors[1])
        }
        let sent = "sent=\(forwardSent)/\(forward.count),\(reverseSent)/\(reverse.count)"
        let received = "received=\(atGuest.count),\(atClient.count)"
        throw MSLError.timedOut("relay transfer stalled \(sent) \(received)")
    }

    private static func peerPollDescriptors(
        _ sockets: RelaySockets, forwardPending: Bool, reversePending: Bool
    ) -> [pollfd] {
        assert(sockets.clientPeer >= 0, "client peer must be valid")
        assert(sockets.guestPeer >= 0, "guest peer must be valid")
        let clientEvents = Int16(POLLIN) | (forwardPending ? Int16(POLLOUT) : 0)
        let guestEvents = Int16(POLLIN) | (reversePending ? Int16(POLLOUT) : 0)
        return [
            pollfd(fd: sockets.clientPeer, events: clientEvents, revents: 0),
            pollfd(fd: sockets.guestPeer, events: guestEvents, revents: 0),
        ]
    }

    private static func writeAvailable(
        _ bytes: [UInt8], offset: inout Int, descriptor: pollfd
    ) throws {
        assert(offset >= 0 && offset <= bytes.count, "write offset must be in bounds")
        let writable = Int16(POLLOUT | POLLHUP)
        guard offset < bytes.count, (descriptor.revents & writable) != 0 else { return }
        let result = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(descriptor.fd, base.advanced(by: offset), bytes.count - offset)
        }
        if result > 0 {
            offset += result
        } else if result < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            throw MSLError.io("peer write failed: \(errno)")
        }
    }

    private static func readAvailable(
        _ bytes: inout [UInt8], expected: Int, descriptor: pollfd
    ) throws {
        assert(bytes.count <= expected, "received bytes must not exceed expected count")
        guard bytes.count < expected, (descriptor.revents & Int16(POLLIN)) != 0 else { return }
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, expected - bytes.count))
        let result = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(descriptor.fd, raw.baseAddress, raw.count)
        }
        if result > 0 {
            bytes.append(contentsOf: buffer.prefix(result))
        } else if result == 0 {
            throw MSLError.io("peer reached EOF before receiving expected bytes")
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            throw MSLError.io("peer read failed: \(errno)")
        }
    }

    static func waitForEOF(_ fd: Int32) throws {
        precondition(fd >= 0, "EOF fd must be valid")
        for _ in 0..<200 {  // bounded to two seconds
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 10)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw MSLError.io("EOF poll failed: \(errno)") }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            let result = Darwin.read(fd, &byte, 1)
            if result == 0 { return }
            if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                continue
            }
            throw MSLError.io("expected EOF, read returned \(result)")
        }
        throw MSLError.timedOut("peer did not receive EOF")
    }

    static func sendAll(_ bytes: [UInt8], to fd: Int32) throws {
        precondition(fd >= 0, "send fd must be valid")
        try setNonblocking(fd)
        var offset = 0
        for _ in 0..<20_000 {  // bounded peer-side progress attempts
            if offset == bytes.count { return }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 10)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw MSLError.io("send poll failed: \(errno)") }
            if ready == 0 { continue }
            try writeAvailable(bytes, offset: &offset, descriptor: descriptor)
        }
        throw MSLError.timedOut("peer send did not finish")
    }

    static func readUntilEOF(_ fd: Int32, expected: Int) throws -> [UInt8] {
        precondition(fd >= 0, "receive fd must be valid")
        precondition(expected >= 0, "expected byte count must be nonnegative")
        try setNonblocking(fd)
        var received: [UInt8] = []
        for _ in 0..<20_000 {  // bounded peer-side progress attempts
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 10)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw MSLError.io("receive poll failed: \(errno)") }
            if ready == 0 { continue }
            let capacity = max(1, min(16 * 1024, expected - received.count))
            var buffer = [UInt8](repeating: 0, count: capacity)
            let result = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if result == 0 { return received }
            if result > 0 {
                received.append(contentsOf: buffer.prefix(result))
                guard received.count <= expected else { throw MSLError.io("received excess bytes") }
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw MSLError.io("receive failed: \(errno)")
            }
        }
        throw MSLError.timedOut("peer did not receive drained EOF")
    }

    static func setNonblocking(_ fd: Int32) throws {
        precondition(fd >= 0, "nonblocking fd must be valid")
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw MSLError.io("F_GETFL failed: \(errno)") }
        guard Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw MSLError.io("F_SETFL failed: \(errno)")
        }
    }

    static func finishPeers(_ sockets: RelaySockets) {
        XCTAssertEqual(Darwin.shutdown(sockets.clientPeer, SHUT_WR), 0)
        XCTAssertEqual(Darwin.shutdown(sockets.guestPeer, SHUT_WR), 0)
    }

    static func closePeers(_ sockets: RelaySockets) {
        if sockets.clientPeer >= 0 { XCTAssertEqual(Darwin.close(sockets.clientPeer), 0) }
        if sockets.guestPeer >= 0 { XCTAssertEqual(Darwin.close(sockets.guestPeer), 0) }
    }
}
