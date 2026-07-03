import Darwin
import Foundation

/// Mirrors guest TCP listener ports onto host `127.0.0.1`. One accept thread
/// polls every mirrored listener plus a self-pipe; each accepted connection gets
/// its own vsock forward to the guest and a `ByteRelay`. Owned by `DaemonCore`.
///
/// `@unchecked Sendable`: all mutable state below is guarded by `lock`; the
/// accept thread only ever reads snapshots taken under it.
public final class PortForwarder: @unchecked Sendable {
    /// Opens vsock 5003, performs the `ForwardHello` handshake for `port`, and
    /// returns the raw guest fd. Injected so unit tests can fake the guest.
    private let connectGuest: @Sendable (UInt16) throws -> Int32
    private let logger: @Sendable (String) -> Void
    private let lock = NSLock()
    private var listeners: [UInt16: Int32] = [:]
    private var failed: Set<UInt16> = []
    private var capped: Set<UInt16> = []
    private var activeRelays = 0
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var acceptThread: Thread?
    private var running = false

    static let maxPorts = 64
    static let maxRelays = 128
    static let backlog: Int32 = 16
    private static let pollTimeoutMs: Int32 = 500

    public init(
        connectGuest: @escaping @Sendable (UInt16) throws -> Int32,
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.connectGuest = connectGuest
        self.logger = logger
    }

    /// Create the self-pipe and start the accept thread. A pipe failure disables
    /// forwarding (the daemon still runs); every later call becomes a no-op.
    public func start() {
        guard let pipe = ForwardSys.makePipe() else {
            logger("port-forward: self-pipe creation failed; forwarding disabled")
            return
        }
        withLock {
            wakeRead = pipe.read
            wakeWrite = pipe.write
            running = true
        }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.stackSize = 512 * 1024
        withLock { acceptThread = thread }
        thread.start()
    }

    /// Reconcile mirrored listeners against the guest's current listener set.
    /// Called from the daemon poll tick (single caller, no concurrent update).
    public func update(ports: [UInt16]) {
        precondition(ports.count <= 4096, "listener list must be bounded")
        let desired = Set(ports)
        let plan = withLock { () -> (open: [UInt16], close: [UInt16])? in
            guard running else { return nil }
            return Self.diff(
                current: Set(listeners.keys), desired: desired, failed: failed,
                cap: Self.maxPorts)
        }
        guard let plan else { return }
        applyClose(plan.close)
        applyOpen(plan.open)
        noteCapped(desired: desired, opened: plan.open)
        pruneMemory(desired: desired)
        wake()
    }

    /// Close every listener, wake the accept thread, and tear down the pipe.
    /// Active relays are left to die on guest EOF.
    public func stop() {
        let (fds, wakeFD) = withLock { () -> ([Int32], Int32) in
            running = false
            let saved = Array(listeners.values)
            listeners = [:]
            return (saved, wakeWrite)
        }
        for fd in fds where fd >= 0 {  // bounded: at most maxPorts listeners
            _ = Darwin.close(fd)
        }
        if wakeFD >= 0 { ForwardSys.poke(wakeFD) }
        let thread = withLock { acceptThread }
        joinAccept(thread)
        withLock {
            closePipeLocked()
            acceptThread = nil
        }
    }

    /// Snapshot of currently mirrored host ports, sorted ascending (for status).
    public func mirroredPorts() -> [UInt16] {
        return withLock { listeners.keys.sorted() }
    }

    private func applyClose(_ ports: [UInt16]) {
        for port in ports {  // bounded: at most the current listener count
            let fd = withLock { listeners.removeValue(forKey: port) }
            if let fd, fd >= 0 { _ = Darwin.close(fd) }
        }
    }

    private func applyOpen(_ ports: [UInt16]) {
        for port in ports {  // bounded: diff caps at maxPorts
            guard let fd = bindLoopback(port: port) else {
                withLock { _ = failed.insert(port) }
                continue
            }
            // A concurrent stop() (poll tick vs teardown are not serialized) may
            // have emptied the map; without this guard the fd would leak and pin
            // the port for the daemon's life. Bail out entirely once stopped.
            let kept = withLock { () -> Bool in
                guard running else { return false }
                listeners[port] = fd
                return true
            }
            guard kept else {
                _ = Darwin.close(fd)
                return
            }
        }
    }

    private func noteCapped(desired: Set<UInt16>, opened: [UInt16]) {
        let openedSet = Set(opened)
        let known = withLock { Set(listeners.keys).union(failed) }
        for port in desired.sorted() where !openedSet.contains(port) && !known.contains(port) {
            let firstTime = withLock { capped.insert(port).inserted }
            if firstTime { logger("port-forward: port cap reached; not mirroring \(port)") }
        }
    }

    private func pruneMemory(desired: Set<UInt16>) {
        withLock {
            failed = failed.intersection(desired)
            capped = capped.intersection(desired)
        }
    }

    /// Bind a nonblocking listener on 127.0.0.1:<port>; nil (and a one-shot log)
    /// on any failure. A bind failure is the mechanism that skips privileged or
    /// already-bound ports (e.g. guest systemd-resolved on 53).
    private func bindLoopback(port: UInt16) -> Int32? {
        precondition(port > 0, "forward port must be positive")
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger("port-forward: socket() for \(port) failed: errno=\(errno)")
            return nil
        }
        var yes: Int32 = 1
        _ = Darwin.setsockopt(
            fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        ForwardSys.setNonBlocking(fd)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, Self.backlog) == 0 else {
            logger("port-forward: bind/listen 127.0.0.1:\(port) failed (errno=\(errno)); skipping")
            _ = Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func acceptLoop() {
        while true {  // sanctioned: the port-forward accept loop runs until stop()
            let snapshot = withLock { () -> AcceptSnapshot in
                AcceptSnapshot(
                    alive: running, pipe: wakeRead,
                    ports: listeners.map { ($0.key, $0.value) })
            }
            guard snapshot.alive, snapshot.pipe >= 0 else { break }
            var pollfds = buildPollfds(snapshot: snapshot.ports, pipeFD: snapshot.pipe)
            let ready = pollfds.withUnsafeMutableBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.poll(base, nfds_t(buf.count), Self.pollTimeoutMs)
            }
            guard ready > 0 else { continue }  // timeout/EINTR: re-snapshot
            drainWake(pollfds)
            acceptReady(pollfds: pollfds, snapshot: snapshot.ports)
        }
    }

    private func buildPollfds(snapshot: [(UInt16, Int32)], pipeFD: Int32) -> [pollfd] {
        assert(pipeFD >= 0, "wake pipe fd must be valid")
        var fds = [pollfd(fd: pipeFD, events: Int16(POLLIN), revents: 0)]
        for entry in snapshot {  // bounded: at most maxPorts listeners
            fds.append(pollfd(fd: entry.1, events: Int16(POLLIN), revents: 0))
        }
        return fds
    }

    private func drainWake(_ pollfds: [pollfd]) {
        guard let first = pollfds.first, (first.revents & Int16(POLLIN)) != 0 else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        for _ in 0..<64 {  // bounded: drain at most 64 wake bytes per tick
            let got = buf.withUnsafeMutableBytes { Darwin.read(first.fd, $0.baseAddress, $0.count) }
            if got <= 0 { break }
        }
    }

    private func acceptReady(pollfds: [pollfd], snapshot: [(UInt16, Int32)]) {
        assert(pollfds.count == snapshot.count + 1, "pollfds must be pipe + listeners")
        for idx in 1..<max(1, pollfds.count) {  // bounded: pipe + maxPorts
            let entry = pollfds[idx]
            guard (entry.revents & Int16(POLLIN)) != 0, idx - 1 < snapshot.count else { continue }
            acceptAll(listenerFD: entry.fd, port: snapshot[idx - 1].0)
        }
    }

    private func acceptAll(listenerFD: Int32, port: UInt16) {
        assert(listenerFD >= 0, "listener fd must be valid")
        for _ in 0..<Self.backlog {  // bounded: drain up to one backlog per tick
            let fd = Darwin.accept(listenerFD, nil, nil)
            guard fd >= 0 else { break }  // EAGAIN/error: nothing more pending
            ForwardSys.setBlocking(fd)
            dispatchRelay(clientFD: fd, port: port)
        }
    }

    private func dispatchRelay(clientFD: Int32, port: UInt16) {
        precondition(clientFD >= 0, "accepted fd must be valid")
        let admitted = withLock { () -> Bool in
            guard activeRelays < Self.maxRelays else { return false }
            activeRelays += 1
            return true
        }
        guard admitted else {
            logger("port-forward: relay cap reached; dropping connection on port \(port)")
            _ = Darwin.close(clientFD)
            return
        }
        Thread.detachNewThread { [weak self] in self?.runRelay(clientFD: clientFD, port: port) }
    }

    private func runRelay(clientFD: Int32, port: UInt16) {
        assert(clientFD >= 0, "relay client fd must be valid")
        defer { withLock { activeRelays = max(0, activeRelays - 1) } }
        let guestFD: Int32
        do {
            guestFD = try connectGuest(port)
        } catch {
            logger("port-forward: guest connect for port \(port) failed: \(error)")
            _ = Darwin.close(clientFD)
            return
        }
        guard guestFD >= 0 else {
            _ = Darwin.close(clientFD)
            return
        }
        ByteRelay(clientFD: clientFD, guestFD: guestFD).run()
    }

    private func wake() {
        let fd = withLock { wakeWrite }
        if fd >= 0 { ForwardSys.poke(fd) }
    }

    private func closePipeLocked() {
        if wakeRead >= 0 { _ = Darwin.close(wakeRead) }
        if wakeWrite >= 0 { _ = Darwin.close(wakeWrite) }
        wakeRead = -1
        wakeWrite = -1
    }

    private func joinAccept(_ thread: Thread?) {
        guard let thread else { return }
        for _ in 0..<200 {  // bounded: wait up to ~2 s for the accept loop to exit
            if thread.isFinished { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension PortForwarder {
    /// Pure listener diff: ports to open (respecting the cap and the failed set)
    /// and ports to close. Retained ports never count against new capacity.
    static func diff(
        current: Set<UInt16>, desired: Set<UInt16>, failed: Set<UInt16>, cap: Int
    ) -> (open: [UInt16], close: [UInt16]) {
        precondition(cap > 0, "port cap must be positive")
        let closable = current.subtracting(desired).sorted()
        let retained = current.count - closable.count
        assert(retained >= 0, "retained listener count cannot be negative")
        let candidates = desired.subtracting(current).subtracting(failed).sorted()
        let room = max(0, cap - retained)
        return (open: Array(candidates.prefix(room)), close: closable)
    }
}

/// One accept-loop iteration's snapshot of forwarder state, taken under the lock
/// so the poll loop never touches shared state directly.
private struct AcceptSnapshot {
    let alive: Bool
    let pipe: Int32
    let ports: [(UInt16, Int32)]
}

/// Raw fd/pipe syscall helpers for `PortForwarder`, kept off the class body.
private enum ForwardSys {
    static func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.pipe(base)
        }
        guard rc == 0 else { return nil }
        setNonBlocking(fds[0])
        return (read: fds[0], write: fds[1])
    }

    static func poke(_ fd: Int32) {
        assert(fd >= 0, "pipe fd must be valid")
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &byte) { Darwin.write(fd, $0, 1) }
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func setBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }
}
