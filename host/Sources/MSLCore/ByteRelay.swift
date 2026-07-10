import Darwin

/// Bidirectional raw relay between two owned data-plane sockets.
final class ByteRelay: @unchecked Sendable {
    private static let pollTimeoutMs: Int32 = 100

    private let clientFD: Int32
    private let guestFD: Int32

    init(clientFD: Int32, guestFD: Int32) {
        precondition(clientFD >= 0, "client fd must be valid")
        precondition(guestFD >= 0, "guest fd must be valid")
        precondition(clientFD != guestFD, "relay fds must be distinct")
        self.clientFD = clientFD
        self.guestFD = guestFD
    }

    func run() {
        assert(clientFD >= 0 && guestFD >= 0, "relay fds must be valid")
        defer { closeOwnedDescriptors() }
        guard configureDescriptors() else { return }

        var clientToGuest = Direction(source: clientFD, sink: guestFD)
        var guestToClient = Direction(source: guestFD, sink: clientFD)
        // sanctioned lifecycle relay loop: peer EOF/error terminates; poll bounds idle waits
        while true {
            guard relayCycle(&clientToGuest, &guestToClient) else { return }
        }
    }

    private func relayCycle(_ forward: inout Direction, _ reverse: inout Direction) -> Bool {
        guard halfCloseIfReady(&forward), halfCloseIfReady(&reverse) else { return false }
        if forward.finished && reverse.finished { return false }
        var descriptors = pollDescriptors(forward, reverse)
        let ready = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.poll(base, nfds_t(buffer.count), Self.pollTimeoutMs)
        }
        if ready < 0 { return errno == EINTR }
        if ready == 0 { return true }
        guard !hasFatalPollEvent(descriptors) else { return false }
        let forwardEvent = service(&forward, source: descriptors[0], sink: descriptors[1])
        guard handle(forwardEvent, &forward, &reverse) else { return false }
        let reverseEvent = service(&reverse, source: descriptors[1], sink: descriptors[0])
        return handle(reverseEvent, &forward, &reverse)
    }

    private func configureDescriptors() -> Bool {
        assert(clientFD >= 0, "client fd must be valid")
        assert(guestFD >= 0, "guest fd must be valid")
        return configureDescriptor(clientFD) && configureDescriptor(guestFD)
    }

    private func configureDescriptor(_ fd: Int32) -> Bool {
        precondition(fd >= 0, "relay fd must be valid")
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        guard Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        var enabled: Int32 = 1
        let result = Darwin.setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return result == 0
    }

    private func pollDescriptors(_ forward: Direction, _ reverse: Direction) -> [pollfd] {
        assert(forward.source == reverse.sink, "client mapping must be symmetric")
        assert(reverse.source == forward.sink, "guest mapping must be symmetric")
        var clientEvents: Int16 = forward.wantsRead ? Int16(POLLIN) : 0
        if reverse.hasPending { clientEvents |= Int16(POLLOUT) }
        var guestEvents: Int16 = reverse.wantsRead ? Int16(POLLIN) : 0
        if forward.hasPending { guestEvents |= Int16(POLLOUT) }
        return [
            pollEntry(fd: clientFD, events: clientEvents),
            pollEntry(fd: guestFD, events: guestEvents),
        ]
    }

    private func pollEntry(fd: Int32, events: Int16) -> pollfd {
        assert(fd >= 0, "poll fd must be valid")
        assert(events >= 0, "poll events must be valid")
        return pollfd(fd: events == 0 ? -1 : fd, events: events, revents: 0)
    }

    private func hasFatalPollEvent(_ descriptors: [pollfd]) -> Bool {
        assert(descriptors.count == 2, "relay polls exactly two descriptors")
        let fatal = Int16(POLLERR | POLLNVAL)
        return descriptors.contains { ($0.revents & fatal) != 0 }
    }

    private func service(
        _ direction: inout Direction, source: pollfd, sink: pollfd
    ) -> RelayEvent {
        assert(source.fd == direction.source || source.fd == -1, "poll source must match direction")
        assert(sink.fd == direction.sink || sink.fd == -1, "poll sink must match direction")
        var event = RelayEvent.active
        let readable = Int16(POLLIN | POLLHUP)
        if direction.wantsRead && (source.revents & readable) != 0 {
            event = direction.readOnce()
            if event == .failed { return .failed }
        }
        let writable = Int16(POLLOUT | POLLHUP)
        if direction.hasPending && (sink.revents & writable) != 0 {
            guard direction.writeOnce() else { return .failed }
        }
        return event
    }

    private func stopReading(_ forward: inout Direction, _ reverse: inout Direction) {
        assert(forward.source == reverse.sink, "forward source must match reverse sink")
        assert(reverse.source == forward.sink, "reverse source must match forward sink")
        forward.readingStopped = true
        reverse.readingStopped = true
    }

    private func handle(
        _ event: RelayEvent, _ forward: inout Direction, _ reverse: inout Direction
    ) -> Bool {
        assert(forward.source == reverse.sink, "forward source must match reverse sink")
        assert(reverse.source == forward.sink, "reverse source must match forward sink")
        if event == .sourceEOF { stopReading(&forward, &reverse) }
        return event != .failed
    }

    private func halfCloseIfReady(_ direction: inout Direction) -> Bool {
        assert(direction.source >= 0, "direction source must be valid")
        assert(direction.sink >= 0, "direction sink must be valid")
        guard direction.readingStopped, !direction.hasPending, !direction.sinkHalfClosed else {
            return true
        }
        let result = Darwin.shutdown(direction.sink, SHUT_WR)
        guard result == 0 || errno == ENOTCONN else { return false }
        direction.sinkHalfClosed = true
        return true
    }

    private func closeOwnedDescriptors() {
        assert(clientFD >= 0, "client fd must be valid")
        assert(guestFD >= 0, "guest fd must be valid")
        closeDescriptor(clientFD)
        closeDescriptor(guestFD)
    }

    private func closeDescriptor(_ fd: Int32) {
        precondition(fd >= 0, "relay fd must be valid")
        let shutdownResult = Darwin.shutdown(fd, SHUT_RDWR)
        assert(shutdownResult == 0 || errno == ENOTCONN || errno == EINVAL)
        let closeResult = Darwin.close(fd)
        assert(closeResult == 0 || errno == EINTR)
    }
}

/// Bytes accepted before reading stops are drained before the sink is half-closed.
private struct Direction {
    let source: Int32
    let sink: Int32
    var buffer = RelayBuffer(capacity: 64 * 1024)
    var readingStopped = false
    var sinkHalfClosed = false

    var wantsRead: Bool { !readingStopped && buffer.freeCount > 0 }
    var hasPending: Bool { !buffer.isEmpty }
    var finished: Bool { readingStopped && !hasPending && sinkHalfClosed }

    mutating func readOnce() -> RelayEvent {
        assert(source >= 0, "direction source must be valid")
        assert(wantsRead, "read requires source capacity")
        let result = buffer.read(from: source)
        if result > 0 { return .active }
        if result == 0 { return .sourceEOF }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return .active }
        return .failed
    }

    mutating func writeOnce() -> Bool {
        assert(sink >= 0, "direction sink must be valid")
        assert(hasPending, "write requires pending bytes")
        let result = buffer.write(to: sink)
        if result > 0 { return true }
        return result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
    }
}

private enum RelayEvent {
    case active
    case sourceEOF
    case failed
}

/// `head` and `count` define the occupied ring; each syscall receives one contiguous span.
private struct RelayBuffer {
    private var storage: [UInt8]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0, "relay buffer capacity must be positive")
        storage = [UInt8](repeating: 0, count: capacity)
        assert(storage.count == capacity, "relay buffer allocation must match capacity")
    }

    var freeCount: Int { storage.count - count }
    var isEmpty: Bool { count.magnitude == 0 }

    mutating func read(from fd: Int32) -> Int {
        precondition(fd >= 0, "read fd must be valid")
        precondition(freeCount > 0, "relay buffer must have free capacity")
        let tail = (head + count) % storage.count
        let available = min(freeCount, storage.count - tail)
        let result = storage.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(fd, base.advanced(by: tail), available)
        }
        if result > 0 {
            assert(result <= available, "read cannot exceed offered capacity")
            count += result
        }
        return result
    }

    mutating func write(to fd: Int32) -> Int {
        precondition(fd >= 0, "write fd must be valid")
        precondition(!isEmpty, "relay buffer must contain bytes")
        let available = min(count, storage.count - head)
        let result = storage.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: head), available)
        }
        if result > 0 {
            assert(result <= available, "write cannot exceed offered bytes")
            head = (head + result) % storage.count
            count -= result
        }
        return result
    }
}
