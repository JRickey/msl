import Darwin
import Foundation
import MSLFSWire

/// Accepts FSKit appex connections on the app-group Unix-domain socket, admits
/// them by peer euid + audit-token designated requirement, validates the hello
/// against a prepared mount (consuming the single-use nonce), opens the guest
/// file-service channel, and splices the hot stream byte-for-byte. One accepted
/// connection per mounted volume; per-connection failures never wedge `mount`.
public final class FSMountListener: @unchecked Sendable {
    private let socketPath: String
    private let authenticator: FSAuthenticator
    private let table: FSMountTable
    private let connectGuest: @Sendable (FSHello) throws -> Int32
    private let logger: @Sendable (String) -> Void
    private let helloTimeout: Double = 5
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopping = false

    public init(
        socketPath: String, authenticator: FSAuthenticator, table: FSMountTable,
        connectGuest: @escaping @Sendable (FSHello) throws -> Int32,
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        precondition(!socketPath.isEmpty, "socket path must not be empty")
        self.socketPath = socketPath
        self.authenticator = authenticator
        self.table = table
        self.connectGuest = connectGuest
        self.logger = logger
    }

    /// Create the app-group container directory, bind the socket, and start the
    /// accept loop on a detached thread. Idempotent-safe: a second start throws.
    public func start() throws {
        let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = try LocalSocket.bindListener(path: socketPath)
        assert(fd >= 0, "bindListener returns a valid fd or throws")
        lock.lock()
        listener = fd
        stopping = false
        lock.unlock()
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    /// Close the listener (unblocking accept) and unlink the socket path.
    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            stopping = true
            let owned = listener
            listener = -1
            return owned
        }
        if fd >= 0 { _ = Darwin.close(fd) }
        _ = Darwin.unlink(socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        assert(fd >= 0, "listener fd must be valid")
        while !lock.withLock({ stopping }) {  // exits when stop() closes the listener
            guard let conn = try? LocalSocket.accept(listener: fd) else {
                if lock.withLock({ stopping }) { return }
                continue
            }
            Thread.detachNewThread { [self] in handle(conn) }
        }
    }

    private func handle(_ fd: Int32) {
        assert(fd >= 0, "connection fd must be valid")
        guard authenticator.admit(fd: fd) else {
            logger("fs: rejected appex connection (peer auth failed)")
            reject(fd, reason: "unauthorized")
            return
        }
        guard let framed = try? VsockClient(fileDescriptor: fd) else {
            _ = Darwin.close(fd)
            return
        }
        try? framed.setReceiveTimeout(seconds: helloTimeout)
        route(framed)
    }

    private func route(_ framed: VsockClient) {
        guard let hello = readHello(framed) else {
            _ = try? framed.send(replyFrame(ok: false, error: "bad hello"))
            framed.close()
            return
        }
        guard table.consumeNonce(distro: hello.distro, mountID: hello.mountID, nonce: hello.nonce)
        else {
            logger("fs: route denied for '\(hello.distro)' (mount id/nonce mismatch or replay)")
            _ = try? framed.send(replyFrame(ok: false, error: "unknown or consumed mount"))
            framed.close()
            return
        }
        spliceToGuest(framed, hello: hello)
    }

    private func spliceToGuest(_ framed: VsockClient, hello: FSHello) {
        let guestFD: Int32
        do {
            guestFD = try connectGuest(hello)
        } catch {
            logger("fs: guest channel open failed for '\(hello.distro)': \(error)")
            _ = try? framed.send(replyFrame(ok: false, error: "guest unavailable"))
            framed.close()
            return
        }
        guard (try? framed.send(replyFrame(ok: true, error: nil))) != nil else {
            _ = Darwin.close(guestFD)
            framed.close()
            return
        }
        logger("fs: routed '\(hello.distro)' mount to guest file service")
        let appexFD = framed.detachDescriptor()
        ByteRelay(clientFD: appexFD, guestFD: guestFD).run()
    }

    private func readHello(_ framed: VsockClient) -> FSHello? {
        guard let frame = try? framed.receive() else { return nil }
        return try? FSHello.decode(frame)
    }

    private func reject(_ fd: Int32, reason: String) {
        assert(fd >= 0, "fd must be valid")
        if let framed = try? VsockClient(fileDescriptor: fd) {
            _ = try? framed.send(replyFrame(ok: false, error: reason))
            framed.close()
        } else {
            _ = Darwin.close(fd)
        }
    }

    private func replyFrame(ok: Bool, error: String?) -> Data {
        let reply = FSControlReply(ok: ok, error: error)
        return (try? reply.encoded()) ?? Data("{\"ok\":false}".utf8)
    }
}
