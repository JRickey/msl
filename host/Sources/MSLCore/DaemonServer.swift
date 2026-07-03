import Darwin
import Foundation

/// Accept loop + per-connection request dispatch for the local control plane.
/// One thread per connection reads framed requests sequentially; `attach`
/// upgrades its connection to a raw byte relay against the guest data plane.
public final class DaemonServer: @unchecked Sendable {
    private let core: DaemonCore
    private let listener: Int32
    private let onShutdown: @Sendable () -> Void

    public init(core: DaemonCore, listener: Int32, onShutdown: @escaping @Sendable () -> Void) {
        precondition(listener >= 0, "listener fd must be valid")
        self.core = core
        self.listener = listener
        self.onShutdown = onShutdown
    }

    /// Accept forever, handing each connection to its own thread. Returns only on
    /// a fatal accept error (the process otherwise exits via the shutdown op).
    public func run() {
        while true {  // sanctioned: the daemon accept loop runs for process life
            guard let fd = try? LocalSocket.accept(listener: listener) else { continue }
            Thread.detachNewThread { [self] in handleConnection(fd) }
        }
    }

    private func handleConnection(_ fd: Int32) {
        guard let framed = try? VsockClient(fileDescriptor: fd) else {
            _ = Darwin.close(fd)
            return
        }
        for _ in 0..<Int.max {  // sequential requests; ends on client close/error
            guard let frame = try? framed.receive() else { break }
            guard let request = try? LocalRequest.decode(frame) else {
                _ = try? framed.send(errorFrame("malformed request"))
                continue
            }
            if !dispatch(request, framed: framed) { break }
        }
        framed.close()
    }

    /// Process one request; returns false when the connection is finished (attach
    /// relay ended, shutdown requested, or a send failed).
    private func dispatch(_ request: LocalRequest, framed: VsockClient) -> Bool {
        switch request {
        case .attach(let sessionID, let token):
            return handleAttach(framed: framed, sessionID: sessionID, token: token)
        case .shutdown:
            _ = try? framed.send(okFrame(LocalEmpty()))
            framed.close()
            onShutdown()
            return false
        default:
            let reply = replyFor(request)
            return (try? framed.send(reply)) != nil
        }
    }

    private func replyFor(_ request: LocalRequest) -> Data {
        do {
            switch request {
            case .status: return okFrame(try core.status())
            case .up(let name): try core.up(name: name); return okFrame(LocalEmpty())
            case .down(let name, let all, let timeoutMs):
                try core.down(name: name, all: all, timeoutMs: timeoutMs)
                return okFrame(LocalEmpty())
            case .shell(let req): return okFrame(try core.openShell(req))
            case .resize(let sessionID, let rows, let cols):
                try core.resize(sessionID: sessionID, rows: rows, cols: cols)
                return okFrame(LocalEmpty())
            case .signal(let sessionID, let sig):
                try core.signal(sessionID: sessionID, signal: sig)
                return okFrame(LocalEmpty())
            case .wait(let sessionID): return okFrame(try core.wait(sessionID: sessionID))
            default: return errorFrame("unsupported request")
            }
        } catch {
            return errorFrame(describe(error))
        }
    }

    /// Attach: consume the token, open the guest data plane, ACK, then relay the
    /// connection raw until the guest closes; reap and close afterward.
    private func handleAttach(framed: VsockClient, sessionID: UInt64, token: String) -> Bool {
        let guestFD: Int32
        do {
            guestFD = try core.beginAttach(sessionID: sessionID, token: token)
        } catch {
            _ = try? framed.send(errorFrame(describe(error)))
            return true
        }
        guard (try? framed.send(okFrame(LocalEmpty()))) != nil else {
            _ = Darwin.close(guestFD)
            core.abortSession(sessionID: sessionID)
            return false
        }
        let clientFD = framed.detachDescriptor()
        SessionRelay(clientFD: clientFD, guestFD: guestFD).run()
        core.endSession(sessionID: sessionID)
        return false
    }

    private func okFrame<Payload: Encodable>(_ payload: Payload) -> Data {
        return (try? LocalReply.ok(payload)) ?? errorFrame("reply encode failed")
    }

    private func errorFrame(_ message: String) -> Data {
        assert(!message.isEmpty, "error message must not be empty")
        return (try? LocalReply.error(message)) ?? Data("{\"ok\":false}".utf8)
    }

    private func describe(_ error: Error) -> String {
        (error as? MSLError)?.description ?? error.localizedDescription
    }
}

/// Bidirectional raw relay for one attached session: client fd <-> guest data
/// fd. Two pump threads; the guest->client pump owns end-of-session detection
/// (the guest closes when the child exits), mirroring `SessionAttach`.
final class SessionRelay: @unchecked Sendable {
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
