import Darwin
import Foundation

/// Bidirectional raw relay between two fds (client <-> guest data plane). Two
/// pump threads; the guest->client pump owns end-of-session detection (the guest
/// closes when the child exits). Reused by session attach and port forwarding.
final class ByteRelay: @unchecked Sendable {
    private let clientFD: Int32
    private let guestFD: Int32
    private let guestDone = DispatchSemaphore(value: 0)
    private let clientDone = DispatchSemaphore(value: 0)

    init(clientFD: Int32, guestFD: Int32) {
        precondition(clientFD >= 0, "client fd must be valid")
        precondition(guestFD >= 0, "guest fd must be valid")
        self.clientFD = clientFD
        self.guestFD = guestFD
    }

    /// Pump both directions until the guest closes, then unblock and join both
    /// pumps before closing the two fds (no fd is touched after close).
    func run() {
        Thread.detachNewThread { [self] in
            pump(from: guestFD, to: clientFD)
            guestDone.signal()
        }
        Thread.detachNewThread { [self] in
            pump(from: clientFD, to: guestFD)
            // client gone: fully shut down the guest fd so the guest->client
            // pump always unblocks and the session terminates exactly once.
            _ = Darwin.shutdown(guestFD, SHUT_RDWR)
            clientDone.signal()
        }
        guestDone.wait()
        _ = Darwin.shutdown(clientFD, SHUT_RDWR)
        _ = Darwin.shutdown(guestFD, SHUT_RDWR)
        clientDone.wait()
        _ = Darwin.close(clientFD)
        _ = Darwin.close(guestFD)
    }

    private func pump(from source: Int32, to sink: Int32) {
        assert(source >= 0 && sink >= 0, "relay fds must be valid")
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {  // stream pump: ends on source EOF/error or a sink error
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(source, raw.baseAddress, raw.count)
            }
            if count > 0 {
                if !writeAll(sink, buffer, count) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) -> Bool {
        precondition(count > 0, "relay write count must be positive")
        var sent = 0
        let cap = count + 64  // bounded: each successful write advances the cursor
        for _ in 0..<cap {
            if sent == count { return true }
            let chunk = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), count - sent)
            }
            if chunk > 0 {
                sent += chunk
            } else if chunk < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return false
    }
}
