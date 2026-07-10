import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class AuthBridgeListenerTests: XCTestCase {
    func testRejectsUnsupportedProtocolVersion() throws {
        let harness = Harness()
        let request = harness.request(surface: .secrets, op: "secret.collection.list", version: 2)

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.code, "bad_request")
    }

    func testRejectsGarbageFrame() throws {
        let harness = Harness()

        let reply = try Reply(harness.listener.handle(Data("not json".utf8)))

        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.code, "bad_request")
    }

    func testRejectsUnknownSessionToken() throws {
        let harness = Harness()
        let peer = AuthPeer(
            id: harness.session.id, token: "wrong", distro: "ubuntu", uid: 1000, pid: 7,
            comm: "secret-tool")
        let request = harness.request(surface: .secrets, op: "secret.collection.list", peer: peer)

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertEqual(reply.code, "denied")
        XCTAssertEqual(reply.message, "bad auth session")
    }

    /// Attribution condition 4: the session's distro must still be running.
    func testRejectsRequestWhenDistroStopped() throws {
        let harness = Harness()
        harness.running.set(false)
        let request = harness.request(surface: .secrets, op: "secret.collection.list")

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertEqual(reply.code, "denied")
        XCTAssertEqual(reply.message, "distro is not running")
    }

    func testRejectsDisabledSurface() throws {
        let harness = Harness(secretsEnabled: false)
        let request = harness.request(surface: .secrets, op: "secret.collection.list")

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertEqual(reply.code, "denied")
        XCTAssertEqual(reply.message, "secrets bridge disabled")
    }

    func testRoutesQueryAndCollectionOperations() throws {
        let harness = Harness()

        let query = try Reply(harness.listener.handle(harness.request(op: "ssh.query")))
        XCTAssertTrue(query.ok)
        XCTAssertEqual(query.data?["ssh_agent"] as? Bool, true)

        let list = try Reply(
            harness.listener.handle(
                harness.request(surface: .secrets, op: "secret.collection.list")))
        XCTAssertTrue(list.ok)
        XCTAssertEqual(list.data?["collections"] as? [String], ["login"])
    }

    /// `secret.query` is not in the spec's operation list.
    func testUnknownOperationsAreDenied() throws {
        let harness = Harness()

        for op in ["secret.query", "secret.item.nope"] {
            let request = harness.request(surface: .secrets, op: op)
            let reply = try Reply(harness.listener.handle(request))
            XCTAssertEqual(reply.code, "denied")
            XCTAssertEqual(reply.message, "unsupported auth operation")
        }
    }

    func testMissingSecretMapsToNotFound() throws {
        let harness = Harness()
        let body = SecretBridgeRequest(
            itemID: "absent", label: nil, attributes: nil, secretBase64: nil)
        let request = harness.request(
            surface: .secrets, op: "secret.item.get", payload: .secret(body))

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertEqual(reply.code, "not_found")
    }

    func testLockedKeychainMapsToLocked() throws {
        let harness = Harness()
        harness.bytes.lockKeychain()
        let body = SecretBridgeRequest(
            itemID: nil, label: "x", attributes: [:],
            secretBase64: Data([1]).base64EncodedString())
        let request = harness.request(
            surface: .secrets, op: "secret.item.create", payload: .secret(body))

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertEqual(reply.code, "locked")
    }

    func testMissingItemIDMapsToBadRequest() throws {
        let harness = Harness()
        let body = SecretBridgeRequest(
            itemID: nil, label: "x", attributes: nil, secretBase64: nil)
        let request = harness.request(
            surface: .secrets, op: "secret.item.delete", payload: .secret(body))

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertEqual(reply.code, "bad_request")
        XCTAssertEqual(reply.message, "secret item id is required")
    }

    func testCreateThenGetRoundTripsThroughTheStore() throws {
        let harness = Harness()
        let secret = Data("hunter2".utf8)
        let created = try Reply(
            harness.listener.handle(
                harness.request(
                    surface: .secrets, op: "secret.item.create",
                    payload: .secret(
                        SecretBridgeRequest(
                            itemID: nil, label: "login", attributes: ["a": "b"],
                            secretBase64: secret.base64EncodedString())))))
        XCTAssertTrue(created.ok)
        let item = try XCTUnwrap(created.data?["item"] as? [String: Any])
        let id = try XCTUnwrap(item["id"] as? String)

        let fetched = try Reply(
            harness.listener.handle(
                harness.request(
                    surface: .secrets, op: "secret.item.get",
                    payload: .secret(
                        SecretBridgeRequest(
                            itemID: id, label: nil, attributes: nil, secretBase64: nil)))))

        XCTAssertTrue(fetched.ok)
        XCTAssertEqual(fetched.data?["secret_b64"] as? String, secret.base64EncodedString())
    }

    /// The host, not just the guest adapter, rejects session-bind forwarding.
    func testSessionBindForwardingIsRejectedWhenPolicyIsOff() throws {
        let harness = Harness()
        let packet = Self.sessionBindPacket(forwarding: true)
        let body = SSHForwardRequest(packetBase64: packet.base64EncodedString())
        let request = harness.request(op: "ssh.forward_packet", payload: .sshForward(body))

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertEqual(reply.code, "denied")
        XCTAssertEqual(reply.message, "ssh-agent forwarding is disabled by policy")
    }

    func testUnavailableHostAgentMapsToHostUnavailable() throws {
        let harness = Harness()
        let body = SSHForwardRequest(packetBase64: Data([11]).base64EncodedString())
        let request = harness.request(op: "ssh.forward_packet", payload: .sshForward(body))

        let reply = try Reply(harness.listener.handle(request))

        XCTAssertEqual(reply.code, "host_unavailable")
    }

    func testAdmissionStopsAtTheConnectionBound() {
        let harness = Harness()

        for _ in 0..<AuthBridgeListener.maxConnections {
            XCTAssertTrue(harness.listener.admit())
        }
        XCTAssertFalse(harness.listener.admit())
    }

    func testAdmissionStopsAfterStop() {
        let harness = Harness()
        harness.listener.stop()
        XCTAssertFalse(harness.listener.admit())
    }

    func testServeAnswersFramedRequestsAndHoldsActivityOnlyPerRequest() throws {
        let harness = Harness(idleTimeout: 0.4)
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let peerFD = fds[0]
        let serveFD = fds[1]
        defer { _ = Darwin.close(peerFD) }
        let served = expectation(description: "serve returned")
        let listener = harness.listener
        Thread {
            listener.serve(fd: serveFD)
            served.fulfill()
        }.start()

        try Self.writeFrame(harness.request(op: "ssh.query"), fd: peerFD)
        let reply = try Reply(Self.readFrame(fd: peerFD))

        XCTAssertTrue(reply.ok)
        XCTAssertEqual(harness.activity.peak, 1)
        XCTAssertEqual(harness.activity.held, 0, "the hold is released before the next receive")
        wait(for: [served], timeout: 5)
        XCTAssertEqual(harness.activity.held, 0)
    }

    /// An attached-but-silent adapter is dropped at the idle deadline and never
    /// holds a daemon activity reference while it waits.
    func testServeClosesIdleConnectionsWithoutHoldingActivity() {
        let harness = Harness(idleTimeout: 0.3)
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let peerFD = fds[0]
        let serveFD = fds[1]
        defer { _ = Darwin.close(peerFD) }
        let served = expectation(description: "idle connection closed")
        let listener = harness.listener
        let start = Date()
        Thread {
            listener.serve(fd: serveFD)
            served.fulfill()
        }.start()

        wait(for: [served], timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
        XCTAssertEqual(harness.activity.peak, 0)
        XCTAssertEqual(harness.activity.held, 0)
    }

    private static func sessionBindPacket(forwarding: Bool) -> Data {
        var packet: [UInt8] = [27]
        packet.append(contentsOf: sshString("session-bind@openssh.com"))
        packet.append(contentsOf: sshString("host-key"))
        packet.append(contentsOf: sshString("session-id"))
        packet.append(contentsOf: sshString("signature"))
        packet.append(forwarding ? 1 : 0)
        return Data(packet)
    }

    private static func sshString(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        let count = UInt32(bytes.count)
        var out: [UInt8] = [
            UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff), UInt8(count & 0xff),
        ]
        out.append(contentsOf: bytes)
        return out
    }

    private static func writeFrame(_ payload: Data, fd: Int32) throws {
        let count = UInt32(payload.count)
        var bytes = [
            UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff), UInt8(count & 0xff),
        ]
        bytes.append(contentsOf: payload)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if sent <= 0 { throw MSLError.io("frame write failed errno=\(errno)") }
            offset += sent
        }
    }

    private static func readFrame(fd: Int32) throws -> Data {
        let header = try readBytes(count: 4, fd: fd)
        let length =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8)
            | Int(header[3])
        return Data(try readBytes(count: length, fd: fd))
    }

    private static func readBytes(count: Int, fd: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if got <= 0 { throw MSLError.io("frame read failed errno=\(errno)") }
            offset += got
        }
        return bytes
    }
}

/// Decoded reply envelope; `data` stays untyped so one helper covers every op.
private struct Reply {
    let ok: Bool
    let code: String?
    let message: String?
    let data: [String: Any]?

    init(_ raw: Data) throws {
        let object = try JSONSerialization.jsonObject(with: raw)
        guard let root = object as? [String: Any], let ok = root["ok"] as? Bool else {
            throw MSLError.protocolMismatch("bad auth reply")
        }
        self.ok = ok
        data = root["data"] as? [String: Any]
        let error = root["error"] as? [String: Any]
        code = error?["code"] as? String
        message = error?["message"] as? String
    }
}

private final class ActivityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var held = 0
    private(set) var peak = 0

    func begin() {
        lock.lock()
        held += 1
        peak = max(peak, held)
        lock.unlock()
    }

    func end() {
        lock.lock()
        held -= 1
        lock.unlock()
    }
}

private final class RunningFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class Harness {
    let sessions = AuthSessionTable()
    let bytes = MemorySecretBytes()
    let activity = ActivityCounter()
    let running = RunningFlag()
    let session: AuthSession
    let listener: AuthBridgeListener

    init(secretsEnabled: Bool = true, idleTimeout: Double = 30) {
        session = sessions.create(
            distro: "ubuntu", sshAgent: true, sshAgentForwarding: false, secrets: secretsEnabled)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msl-auth-\(UUID().uuidString)")
            .appendingPathComponent("secrets.json")
        let counter = activity
        let flag = running
        listener = AuthBridgeListener(
            sessions: sessions, sshProxy: HostSSHAgentProxy(socketPath: nil),
            secrets: KeychainSecretStore(url: url, bytes: bytes),
            logger: { _ in }, beginActivity: { counter.begin() }, endActivity: { counter.end() },
            isDistroRunning: { name in name == "ubuntu" && flag.get() },
            idleTimeout: idleTimeout, requestTimeout: 1)
    }

    func request(
        surface: AuthSurface = .sshAgent, op: String, version: UInt32 = 1,
        peer: AuthPeer? = nil, payload: AuthPayload = .empty
    ) -> Data {
        let resolved =
            peer
            ?? AuthPeer(
                id: session.id, token: session.token, distro: "ubuntu", uid: 1000, pid: 7,
                comm: "msl-test")
        let request = AuthBridgeRequest(
            version: version, id: 1, surface: surface, session: resolved, op: op, req: payload)
        guard let encoded = try? JSONEncoder().encode(request) else {
            preconditionFailure("auth request must encode")
        }
        return encoded
    }
}
