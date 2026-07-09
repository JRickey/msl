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
        case .guiConnect(let name):
            return handleGuiConnect(framed: framed, name: name)
        case .shutdown:
            // Stop the VM (releasing image locks) before acknowledging, so the
            // client's "shut down" means resources are actually free.
            core.shutdown()
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
            return try replyBody(for: request)
        } catch {
            return errorFrame(describe(error))
        }
    }

    private func replyBody(for request: LocalRequest) throws -> Data {
        switch request {
        case .status, .up, .down:
            return try lifecycleReply(request)
        case .shell, .capture, .resize, .signal, .wait:
            return try sessionReply(request)
        case .guiProbe, .guiStart, .guiStatus, .guiStop, .guiLaunch:
            return try guiReply(request)
        case .mountPrepare, .mountCommit, .mountUnmount, .mountStatus:
            return try mountReply(request)
        case .authStatus(let name):
            return okFrame(try core.authStatus(name: name))
        default:
            return errorFrame("unsupported request")
        }
    }

    private func lifecycleReply(_ request: LocalRequest) throws -> Data {
        switch request {
        case .status:
            return okFrame(try core.status())
        case .up(let name):
            try core.up(name: name)
            return okFrame(LocalEmpty())
        case .down(let name, let all, let timeoutMs):
            try core.down(name: name, all: all, timeoutMs: timeoutMs)
            return okFrame(LocalEmpty())
        default:
            return errorFrame("unsupported lifecycle request")
        }
    }

    private func sessionReply(_ request: LocalRequest) throws -> Data {
        switch request {
        case .shell(let req):
            return okFrame(try core.openShell(req))
        case .capture(let req):
            return okFrame(try core.capture(req))
        case .resize(let sessionID, let rows, let cols):
            try core.resize(sessionID: sessionID, rows: rows, cols: cols)
            return okFrame(LocalEmpty())
        case .signal(let sessionID, let sig):
            try core.signal(sessionID: sessionID, signal: sig)
            return okFrame(LocalEmpty())
        case .wait(let sessionID):
            return okFrame(try core.wait(sessionID: sessionID))
        default:
            return errorFrame("unsupported session request")
        }
    }

    private func mountReply(_ request: LocalRequest) throws -> Data {
        switch request {
        case .mountPrepare(let name, let readonly):
            return okFrame(try core.prepareMount(name: name, readonly: readonly))
        case .mountCommit(let name, let mountpoint):
            try core.finishMount(name: name, mountpoint: mountpoint)
            return okFrame(LocalEmpty())
        case .mountUnmount(let name, let force):
            try core.unmount(name: name, force: force)
            return okFrame(LocalEmpty())
        case .mountStatus: return okFrame(core.mountStatus())
        default: return errorFrame("unsupported request")
        }
    }

    private func guiReply(_ request: LocalRequest) throws -> Data {
        switch request {
        case .guiProbe(let req): return okFrame(try core.guiProbe(req))
        case .guiStart(let req): return okFrame(try core.guiStart(req))
        case .guiStatus(let req): return okFrame(try core.guiStatus(req))
        case .guiStop(let req): return okFrame(try core.guiStop(req))
        case .guiLaunch(let req): return okFrame(try core.guiLaunch(req))
        default: return errorFrame("unsupported request")
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
        ByteRelay(clientFD: clientFD, guestFD: guestFD).run()
        core.endSession(sessionID: sessionID)
        return false
    }

    /// GUI connect: open the guest surface plane, ACK, then relay the connection
    /// raw until either side closes; balance the op reference on the way out.
    private func handleGuiConnect(framed: VsockClient, name: String?) -> Bool {
        let guestFD: Int32
        do {
            guestFD = try core.beginGuiConnect(name: name)
        } catch {
            _ = try? framed.send(errorFrame(describe(error)))
            return true
        }
        guard (try? framed.send(okFrame(LocalEmpty()))) != nil else {
            _ = Darwin.close(guestFD)
            core.endGuiConnect()
            return false
        }
        let clientFD = framed.detachDescriptor()
        ByteRelay(clientFD: clientFD, guestFD: guestFD).run()
        core.endGuiConnect()
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
