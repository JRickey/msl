import Darwin
import Foundation

/// One interop connection's lifecycle on its own thread: framed hello, spawn,
/// tagged-frame stdio pump, exit propagation. `@unchecked Sendable`: `reaped`
/// is guarded by `childLock`; everything else is immutable after init.
final class InteropSession: @unchecked Sendable {
    private let fd: Int32
    private let admitted: Bool
    private let spawner: @Sendable (MacExecHello) throws -> MacProcess
    private let logger: @Sendable (String) -> Void
    private let beginActivity: @Sendable () -> Void
    private let endActivity: @Sendable () -> Void
    private let sendLock = NSLock()
    private let childLock = NSLock()
    private var reaped = false

    static let helloTimeout = 10.0
    static let frameDataCap = 64 * 1024

    init(
        fd: Int32, admitted: Bool,
        spawner: @escaping @Sendable (MacExecHello) throws -> MacProcess,
        logger: @escaping @Sendable (String) -> Void,
        beginActivity: @escaping @Sendable () -> Void,
        endActivity: @escaping @Sendable () -> Void
    ) {
        precondition(fd >= 0, "session fd must be valid")
        self.fd = fd
        self.admitted = admitted
        self.spawner = spawner
        self.logger = logger
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    /// Drive the whole session. Over-cap/rejected connections get a framed error
    /// and no activity bracket; admitted ones bracket daemon activity throughout.
    func run() {
        guard admitted else {
            rejectAndClose("too many interop sessions")
            return
        }
        beginActivity()
        defer { endActivity() }
        runAdmitted()
    }

    private func runAdmitted() {
        let client: VsockClient
        do {
            client = try VsockClient(fileDescriptor: fd)
            try client.setReceiveTimeout(seconds: Self.helloTimeout)
        } catch {
            logger("interop: fd setup failed: \(error)")
            _ = Darwin.close(fd)
            return
        }
        let hello: MacExecHello
        do {
            hello = try MacExecHello.decode(try client.receive())
        } catch {
            replyError(client, "bad hello: \(error)")
            return
        }
        let proc: MacProcess
        do {
            proc = try spawner(hello)
        } catch {
            replyError(client, "spawn failed: \(error)")
            return
        }
        do {
            try client.send(try InteropReply.ok().encoded())
        } catch {
            logger("interop: reply send failed: \(error)")
            reap(proc)
            client.close()
            return
        }
        // The hello's SO_RCVTIMEO must not leak into the data phase: an idle
        // interactive session would otherwise trip a fatal read timeout.
        try? client.setReceiveTimeout(seconds: 0)
        let raw = client.detachDescriptor()
        assert(raw >= 0, "detached fd must be valid")
        pump(proc: proc, sock: raw)
    }

    private func pump(proc: MacProcess, sock: Int32) {
        assert(sock >= 0, "socket fd must be valid")
        switch proc.stdio {
        case .pty(let primary):
            pumpPTY(primary: primary, sock: sock, pid: proc.pid)
        case .pipes(let stdin, let stdout, let stderr):
            pumpPipes(stdin: stdin, stdout: stdout, stderr: stderr, sock: sock, pid: proc.pid)
        }
    }

    private func pumpPTY(primary: Int32, sock: Int32, pid: pid_t) {
        assert(primary >= 0 && sock >= 0, "pty pump fds must be valid")
        let outputDone = DispatchSemaphore(value: 0)
        let inputDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            pumpFDToSocket(source: primary, sock: sock, tag: .stdout)
            outputDone.signal()
        }
        Thread.detachNewThread { [self] in
            pumpSocketToPTY(sock: sock, primary: primary)
            killIfUnreaped(pid)  // shim gone: only child death unblocks the output pump
            inputDone.signal()
        }
        outputDone.wait()
        sendExit(sock: sock, code: reapChild(pid))
        _ = Darwin.shutdown(sock, SHUT_RDWR)
        inputDone.wait()
        _ = Darwin.close(primary)
        _ = Darwin.close(sock)
    }

    private func pumpPipes(stdin: Int32, stdout: Int32, stderr: Int32, sock: Int32, pid: pid_t) {
        assert(sock >= 0, "socket fd must be valid")
        assert(stdout >= 0 && stderr >= 0, "output fds must be valid")
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let inDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            pumpFDToSocket(source: stdout, sock: sock, tag: .stdout)
            outDone.signal()
        }
        Thread.detachNewThread { [self] in
            pumpFDToSocket(source: stderr, sock: sock, tag: .stderr)
            errDone.signal()
        }
        Thread.detachNewThread { [self] in
            pumpSocketToPipe(sock: sock, stdinFD: stdin)
            killIfUnreaped(pid)  // shim gone: child death closes the output pipes
            inDone.signal()
        }
        outDone.wait()
        errDone.wait()
        sendExit(sock: sock, code: reapChild(pid))
        _ = Darwin.shutdown(sock, SHUT_RDWR)
        inDone.wait()
        _ = Darwin.close(stdout)
        _ = Darwin.close(stderr)
        _ = Darwin.close(sock)
    }

    /// waitpid, then mark the pid reaped under `childLock` so a racing
    /// disconnect-kill can never signal a recycled pid. A waitpid error maps to
    /// 253, distinct from the shim's local 255/254 codes.
    private func reapChild(_ pid: pid_t) -> Int32 {
        assert(pid > 0, "reap requires a positive pid")
        let code = MacExec.wait(pid: pid)
        childLock.lock()
        reaped = true
        childLock.unlock()
        return code < 0 ? 253 : code
    }

    /// SIGKILL the child unless it was already reaped. Kill-before-reap is safe
    /// (a zombie's pid cannot be recycled); the flag closes the after-reap case.
    private func killIfUnreaped(_ pid: pid_t) {
        assert(pid > 0, "kill requires a positive pid")
        childLock.lock()
        defer { childLock.unlock() }
        if !reaped { _ = Darwin.kill(pid, SIGKILL) }
    }
}

/// Low-level pump and framing helpers, split out to keep the class body within
/// the type-length budget.
extension InteropSession {
    private func pumpFDToSocket(source: Int32, sock: Int32, tag: InteropTag) {
        assert(source >= 0, "source fd must be valid")
        assert(sock >= 0, "socket fd must be valid")
        var buffer = [UInt8](repeating: 0, count: Self.frameDataCap)
        while true {  // sanctioned: output pump, ends on source EOF/error or send failure
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(source, raw.baseAddress, raw.count)
            }
            if count > 0 {
                if !sendFrame(sock: sock, tag: tag, bytes: Array(buffer.prefix(count))) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private func pumpSocketToPTY(sock: Int32, primary: Int32) {
        assert(primary >= 0, "primary fd must be valid")
        while true {  // sanctioned: input pump, ends on shim EOF/framing error
            guard let payload = readFrame(sock), let tag = payload.first else { break }
            let data = Array(payload.dropFirst())
            switch InteropTag(rawValue: tag) {
            case .stdin:
                if !writeAllFD(primary, data) { return }
            case .winch:
                applyWinch(primary: primary, body: data)
            case .stdinEOF:
                break  // pty carries EOF in-band; nothing to close
            default:
                break  // ignore host-only or unknown tags
            }
        }
    }

    private func pumpSocketToPipe(sock: Int32, stdinFD: Int32) {
        assert(stdinFD >= 0, "stdin fd must be valid")
        var stdinOpen = true
        while true {  // sanctioned: input pump, ends on shim EOF/framing error
            guard let payload = readFrame(sock), let tag = payload.first else { break }
            let data = Array(payload.dropFirst())
            switch InteropTag(rawValue: tag) {
            case .stdin:
                if stdinOpen && !writeAllFD(stdinFD, data) {
                    _ = Darwin.close(stdinFD)
                    stdinOpen = false
                }
            case .stdinEOF:
                if stdinOpen {
                    _ = Darwin.close(stdinFD)
                    stdinOpen = false
                }
            default:
                break  // ignore host-only or unknown tags
            }
        }
        if stdinOpen { _ = Darwin.close(stdinFD) }
    }

    private func applyWinch(primary: Int32, body: [UInt8]) {
        assert(primary >= 0, "primary fd must be valid")
        guard let resize = try? JSONDecoder().decode(InteropResize.self, from: Data(body)) else {
            return
        }
        var win = winsize(
            ws_row: resize.rows, ws_col: resize.cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(primary, TIOCSWINSZ, &win)
    }

    private func sendExit(sock: Int32, code: Int32) {
        assert(sock >= 0, "socket fd must be valid")
        let body = (try? InteropExit(code: code).encoded()).map { Array($0) } ?? []
        _ = sendFrame(sock: sock, tag: .exit, bytes: body)
    }

    private func sendFrame(sock: Int32, tag: InteropTag, bytes: [UInt8]) -> Bool {
        assert(sock >= 0, "socket fd must be valid")
        assert(bytes.count <= Self.frameDataCap, "data frame exceeds the 64 KiB cap")
        sendLock.lock()
        defer { sendLock.unlock() }
        return writeFrame(sock: sock, tag: tag, bytes: bytes)
    }

    private func writeFrame(sock: Int32, tag: InteropTag, bytes: [UInt8]) -> Bool {
        let length = bytes.count + 1
        guard length <= Proto.maxPayload else { return false }
        var frame = [UInt8](repeating: 0, count: 4 + length)
        frame[0] = UInt8((length >> 24) & 0xff)
        frame[1] = UInt8((length >> 16) & 0xff)
        frame[2] = UInt8((length >> 8) & 0xff)
        frame[3] = UInt8(length & 0xff)
        frame[4] = tag.rawValue
        if !bytes.isEmpty { frame.replaceSubrange(5..<frame.count, with: bytes) }
        return writeAllFD(sock, frame)
    }

    private func writeAllFD(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        if bytes.isEmpty { return true }
        assert(fd >= 0, "write fd must be valid")
        var sent = 0
        let cap = bytes.count + 64  // bounded: each write advances >=1 byte
        for _ in 0..<cap {
            if sent == bytes.count { return true }
            let chunk = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
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

    private func readFrame(_ fd: Int32) -> [UInt8]? {
        guard let header = readExactly(fd, count: 4) else { return nil }
        assert(header.count == 4, "header read must return four bytes")
        let length =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8)
            | Int(header[3])
        guard length >= 1, length <= Self.frameDataCap + 1 else { return nil }
        return readExactly(fd, count: length)
    }

    private func readExactly(_ fd: Int32, count: Int) -> [UInt8]? {
        assert(count >= 0, "read count must be non-negative")
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        let cap = count + 64  // bounded: each read advances >=1 byte
        for _ in 0..<cap {
            if got == count { return buffer }
            let chunk = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if chunk > 0 {
                got += chunk
            } else if chunk == 0 {
                return nil
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return nil
    }

    private func rejectAndClose(_ message: String) {
        assert(!message.isEmpty, "rejection needs a message")
        logger("interop: \(message)")
        guard let client = try? VsockClient(fileDescriptor: fd) else {
            _ = Darwin.close(fd)
            return
        }
        if let data = try? InteropReply.failure(message).encoded() { try? client.send(data) }
        client.close()
    }

    private func replyError(_ client: VsockClient, _ message: String) {
        assert(!message.isEmpty, "error reply needs a message")
        logger("interop: \(message)")
        if let data = try? InteropReply.failure(message).encoded() { try? client.send(data) }
        client.close()
    }

    private func reap(_ proc: MacProcess) {
        assert(proc.pid > 0, "reap requires a live pid")
        _ = Darwin.kill(proc.pid, SIGKILL)
        _ = MacExec.wait(pid: proc.pid)
        switch proc.stdio {
        case .pty(let primary):
            _ = Darwin.close(primary)
        case .pipes(let stdin, let stdout, let stderr):
            _ = Darwin.close(stdin)
            _ = Darwin.close(stdout)
            _ = Darwin.close(stderr)
        }
    }
}
