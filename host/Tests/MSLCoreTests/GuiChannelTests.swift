import Darwin
import Foundation
import XCTest

@testable import MSLCore

private final class GuiChannelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var handlerSawOpenPeer = false

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func recordPeerOpen(_ open: Bool) {
        lock.lock()
        handlerSawOpenPeer = open
        lock.unlock()
    }

    func snapshot() -> (events: [String], handlerSawOpenPeer: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (events, handlerSawOpenPeer)
    }
}

private struct GuiShutdownObservation: @unchecked Sendable {
    let channel: GuiChannel
    let peer: Int32
    let releaseRead: DispatchSemaphore
    let probe: GuiChannelProbe
    let stalled: XCTestExpectation
    let disconnected: XCTestExpectation
}

final class GuiChannelTests: XCTestCase {
    func testSaturatedSendSignalsBeforeShutdownAndOnlyOnce() throws {
        let fds = try Self.socketPair()
        defer { _ = Darwin.close(fds[1]) }
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let readEntered = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let channel = try GuiChannel(
            fd: fds[0],
            beforeWrite: {
                writerEntered.signal()
                releaseWriter.wait()
            },
            afterReadLease: {
                readEntered.signal()
                releaseRead.wait()
            })
        defer {
            channel.close()
            releaseRead.signal()
            for _ in 0..<64 { releaseWriter.signal() }
        }

        let probe = GuiChannelProbe()
        let stalled = expectation(description: "stall handler")
        let disconnected = expectation(description: "reader disconnected")
        Self.observeShutdown(
            GuiShutdownObservation(
                channel: channel, peer: fds[1], releaseRead: releaseRead, probe: probe,
                stalled: stalled, disconnected: disconnected))
        XCTAssertEqual(readEntered.wait(timeout: .now() + .seconds(1)), .success)

        for _ in 0..<64 {
            channel.send(type: GuiType.presentAck.rawValue, flags: 0, payload: Data())
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + .seconds(1)), .success)
        let start = DispatchTime.now().uptimeNanoseconds
        channel.send(type: GuiType.presentAck.rawValue, flags: 0, payload: Data())
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertLessThan(elapsed, 200_000_000)
        Self.repeatSends(channel)

        wait(for: [stalled, disconnected], timeout: 1)
        let result = probe.snapshot()
        XCTAssertEqual(result.events, ["stall", "disconnect"])
        XCTAssertTrue(result.handlerSawOpenPeer)
        XCTAssertEqual(Darwin.fcntl(fds[0], F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)

        XCTAssertEqual(Darwin.dup2(fds[1], fds[0]), fds[0])
        defer { _ = Darwin.close(fds[0]) }
        Self.repeatSends(channel)
        XCTAssertGreaterThanOrEqual(Darwin.fcntl(fds[0], F_GETFD), 0)
        XCTAssertEqual(probe.snapshot().events, ["stall", "disconnect"])
    }

    func testCloseDefersDescriptorCloseUntilReadLeaseReleases() throws {
        let fds = try Self.socketPair()
        defer { _ = Darwin.close(fds[1]) }
        let readEntered = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let readFinished = expectation(description: "leased read finished")
        let probe = GuiChannelProbe()
        let channel = try GuiChannel(fd: fds[0], beforeWrite: nil) {
            readEntered.signal()
            releaseRead.wait()
        }
        defer {
            channel.close()
            releaseRead.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try channel.readFrame()
                probe.record("unexpected-frame")
            } catch {
                probe.record("closed")
            }
            readFinished.fulfill()
        }
        XCTAssertEqual(readEntered.wait(timeout: .now() + .seconds(1)), .success)

        channel.close()
        XCTAssertGreaterThanOrEqual(Darwin.fcntl(fds[0], F_GETFD), 0)
        XCTAssertThrowsError(try channel.readFrame())
        releaseRead.signal()
        wait(for: [readFinished], timeout: 1)

        XCTAssertEqual(probe.snapshot().events, ["closed"])
        XCTAssertEqual(Darwin.fcntl(fds[0], F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    private static func repeatSends(_ channel: GuiChannel) {
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            channel.send(type: GuiType.presentAck.rawValue, flags: 0, payload: Data())
        }
    }

    private static func observeShutdown(_ observation: GuiShutdownObservation) {
        observation.stalled.assertForOverFulfill = true
        observation.channel.setStallHandler {
            observation.probe.record("stall")
            observation.probe.recordPeerOpen(peerHasNoEOF(observation.peer))
            observation.releaseRead.signal()
            observation.stalled.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try observation.channel.readFrame()
                observation.probe.record("unexpected-frame")
            } catch {
                observation.probe.record("disconnect")
            }
            observation.disconnected.fulfill()
        }
    }

    private static func peerHasNoEOF(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        let savedErrno = errno
        assert(result <= 0, "empty ordering socket must not contain data")
        return result < 0 && (savedErrno == EAGAIN || savedErrno == EWOULDBLOCK)
    }

    private static func socketPair() throws -> [Int32] {
        var fds = [Int32](repeating: -1, count: 2)
        let result = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        guard result == 0, fds[0] >= 0, fds[1] >= 0 else {
            throw MSLError.io("socketpair failed with errno \(errno)")
        }
        return fds
    }
}
