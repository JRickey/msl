import Darwin
import Foundation
import XCTest

@testable import MSLCore

/// G1 backend-abstraction tests that need no VZ: the factory's backend gating
/// and the transport-free `ReverseVsockHandler` logic exercised over a
/// socketpair (the VZ adapter that dup's the fd is not involved here, so the
/// handler simply receives an already-owned blocking fd).
final class VMBackendTests: XCTestCase {
    // MARK: - factory

    func testFactoryRejectsKrunBackend() throws {
        let spec = try Self.makeSpec(backend: .krun)
        XCTAssertThrowsError(try VMBackendFactory.make(spec: spec)) { error in
            guard case MSLError.configuration = error else {
                return XCTFail("krun must fail with a configuration error, got \(error)")
            }
        }
    }

    func testFactoryBuildsVZBackend() throws {
        let spec = try Self.makeSpec(backend: .vz)
        let backend = try VMBackendFactory.make(spec: spec)
        XCTAssertEqual(backend.capabilities.kind, .vz)
        XCTAssertTrue(backend.capabilities.rosetta)
        XCTAssertFalse(backend.capabilities.gpu)
    }

    // MARK: - reverse handler

    func testStoppedListenerRejectsAndClosesFd() throws {
        let listener = Self.makeListener(sink: LogSink())
        listener.stop()
        let pair = try Self.socketPair()
        try Self.setReceiveTimeout(pair.peer, seconds: 1)
        XCTAssertFalse(listener.handleReverseConnection(fd: pair.owned, port: 5010))
        XCTAssertTrue(Self.readsEOF(pair.peer), "reject must close the handed-off fd")
        _ = Darwin.close(pair.peer)
    }

    func testAdmittedListenerAcceptsAndSessionDrainsFd() throws {
        let sink = LogSink()
        let listener = Self.makeListener(sink: sink)
        let pair = try Self.socketPair()
        XCTAssertTrue(listener.handleReverseConnection(fd: pair.owned, port: 5010))
        // Send a framed-but-invalid hello: the detached session must decode-fail,
        // reply an error, and log "bad hello". The peer stays open until then so
        // the session's error reply cannot raise SIGPIPE in the test runner
        // (VsockClient writes with no SO_NOSIGPIPE). It owns/closes pair.owned.
        try Self.writeFrame(pair.peer, payload: Data("x".utf8))
        XCTAssertEqual(
            sink.helloFailed.wait(timeout: .now() + 2), .success,
            "admitted session must run and report the bad hello")
        _ = Darwin.close(pair.peer)
    }

    func testAcceptFailureDefaultIsNoOp() {
        // A minimal handler that does not override the failure hook: invoking the
        // default implementation must be a harmless no-op.
        MinimalReverseHandler().handleReverseAcceptFailure(errno: EBADF, port: 5010)
    }

    // MARK: - helpers

    private static func makeListener(sink: LogSink) -> InteropListener {
        let spawner: @Sendable (MacExecHello) throws -> MacProcess = { _ in
            throw MSLError.invalidArgument("spawn not expected in these tests")
        }
        return InteropListener(
            spawner: spawner,
            logger: { [sink] message in sink.record(message) },
            beginActivity: {}, endActivity: {})
    }

    private static func makeSpec(backend: VMBackendKind) throws -> BootSpec {
        let kernel = try writeTempFile("kernel")
        let initramfs = try writeTempFile("initramfs")
        defer {
            try? FileManager.default.removeItem(atPath: kernel)
            try? FileManager.default.removeItem(atPath: initramfs)
        }
        return try BootSpec(
            kernelPath: kernel, initramfsPath: initramfs, commandLine: "console=hvc0",
            cpuCount: 1, memoryMiB: 512, consoleLogPath: nil, execCommand: nil, timeout: 5,
            backend: backend)
    }

    private static func writeTempFile(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-\(name)-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        return url.path
    }

    private static func socketPair() throws -> (owned: Int32, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return socketpair(AF_UNIX, SOCK_STREAM, 0, base)
        }
        guard rc == 0 else { throw MSLError.io("socketpair failed errno=\(errno)") }
        return (owned: fds[0], peer: fds[1])
    }

    /// Write one control-plane frame (4-byte big-endian length + payload), the
    /// framing `VsockClient.receive` expects. Small payloads only; a socketpair
    /// buffer always absorbs them in one write.
    private static func writeFrame(_ fd: Int32, payload: Data) throws {
        var frame = [UInt8](repeating: 0, count: 4)
        let count = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: count) { frame.replaceSubrange(0..<4, with: $0) }
        frame.append(contentsOf: payload)
        let written = frame.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.write(fd, base, buffer.count)
        }
        guard written == frame.count else {
            throw MSLError.io("frame write returned \(written) errno=\(errno)")
        }
    }

    private static func setReceiveTimeout(_ fd: Int32, seconds: Int) throws {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        let rc = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard rc == 0 else { throw MSLError.io("setsockopt SO_RCVTIMEO failed errno=\(errno)") }
    }

    /// Read one byte and report whether the peer is at EOF (a closed fd). With a
    /// receive timeout set, a still-open fd trips the timeout and returns false.
    private static func readsEOF(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let count = withUnsafeMutablePointer(to: &byte) { pointer in
            Darwin.read(fd, pointer, 1)
        }
        return count == 0
    }
}

/// A `ReverseVsockHandler` that implements only the required method, so the
/// default `handleReverseAcceptFailure` extension is what runs in the test.
private final class MinimalReverseHandler: ReverseVsockHandler, @unchecked Sendable {
    func handleReverseConnection(fd: Int32, port: UInt32) -> Bool {
        _ = Darwin.close(fd)
        return false
    }
}

/// Thread-safe log capture. `helloFailed` signals when the interop session
/// reports a bad hello, letting a test await the detached session deterministically.
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    let helloFailed = DispatchSemaphore(value: 0)

    func record(_ message: String) {
        lock.lock()
        lines.append(message)
        lock.unlock()
        if message.contains("bad hello") { helloFailed.signal() }
    }
}
