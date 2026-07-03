import Darwin
import Foundation

/// How an attached session ended: the child exited (with the waited code) or a
/// terminating signal reached msl while attached.
public enum AttachOutcome: Sendable {
    case exited(Int32)
    case signaled(Int32)
}

/// The control-side operations `SessionAttach` needs: resize (SIGWINCH) and the
/// non-blocking exit poll. The vsock `ControlClient` and the daemon's
/// `LocalClient` both satisfy this, so the same attach machinery drives `msl up`
/// and `msl shell`.
public protocol SessionControlChannel: Sendable {
    func sessionResize(sessionID: UInt64, rows: UInt16, cols: UInt16) throws
    func sessionWait(sessionID: UInt64) throws -> SessionWaitData
}

extension ControlClient: SessionControlChannel {}

/// Binds a PTY-backed guest session to the local terminal. One thread pumps
/// stdin -> data socket, another pumps data socket -> stdout; the second owns
/// end-of-session detection (agent closes the data connection on child exit).
/// SIGWINCH -> session_resize and terminating signals run on dedicated queues;
/// the terminal is restored on every exit path.
public final class SessionAttach: @unchecked Sendable {
    private let control: any SessionControlChannel
    private let sessionID: UInt64
    private let dataFD: Int32
    private let inFD: Int32 = STDIN_FILENO
    private let outFD: Int32 = STDOUT_FILENO
    private let done = DispatchSemaphore(value: 0)
    private let winchQueue = DispatchQueue(label: "msl.winch", qos: .userInitiated)
    private let termQueue = DispatchQueue(label: "msl.attach.signal", qos: .userInitiated)
    private let outcomeLock = NSLock()
    private var outcomeSet = false
    private var signaledWith: Int32 = 0
    private var winchSource: DispatchSourceSignal?
    private var intSource: DispatchSourceSignal?
    private var termSource: DispatchSourceSignal?

    public init(control: any SessionControlChannel, sessionID: UInt64, dataFD: Int32) {
        precondition(dataFD >= 0, "data-plane fd must be valid")
        self.control = control
        self.sessionID = sessionID
        self.dataFD = dataFD
    }

    /// Run the attach to completion and return the session outcome. The tty is
    /// raw for the duration and restored before this returns on any path.
    public func run() throws -> AttachOutcome {
        let saved = try Terminal.makeRaw(inFD)
        defer { Terminal.restore(inFD, saved) }
        installWinch()
        installTerminatingSignals()
        sendInitialResize()
        startPumps()
        done.wait()
        teardown()
        return try resolveOutcome()
    }

    private func startPumps() {
        Thread.detachNewThread { [self] in pumpInToData() }
        Thread.detachNewThread { [self] in pumpDataToOut() }
    }

    /// stdin -> data socket. A PTY has no stdin-EOF concept (Ctrl-D travels
    /// as a byte), so stdin EOF only stops this pump — half-closing the
    /// socket would make the agent hang up the PTY and SIGHUP the child.
    private func pumpInToData() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {  // stream pump: terminates on stdin EOF/error
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(inFD, raw.baseAddress, raw.count)
            }
            if count > 0 {
                if !writeAll(dataFD, buffer, count) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    /// data socket -> stdout. A zero-length read means the agent closed the
    /// connection on child exit: signal completion.
    private func pumpDataToOut() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {  // stream pump: terminates on data-socket close/error
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(dataFD, raw.baseAddress, raw.count)
            }
            if count > 0 {
                if !writeAll(outFD, buffer, count) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        done.signal()
    }

    private func installWinch() {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: winchQueue)
        source.setEventHandler { [weak self] in self?.resizeToCurrent() }
        source.resume()
        winchSource = source
    }

    private func installTerminatingSignals() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        intSource = makeTerminatingSource(SIGINT)
        termSource = makeTerminatingSource(SIGTERM)
    }

    private func makeTerminatingSource(_ sig: Int32) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: termQueue)
        source.setEventHandler { [weak self] in
            self?.recordSignal(sig)
            self?.done.signal()
        }
        source.resume()
        return source
    }

    private func sendInitialResize() {
        guard let size = currentWindowSize() else { return }
        try? control.sessionResize(sessionID: sessionID, rows: size.rows, cols: size.cols)
    }

    private func resizeToCurrent() {
        guard let size = currentWindowSize() else { return }
        try? control.sessionResize(sessionID: sessionID, rows: size.rows, cols: size.cols)
    }

    private func currentWindowSize() -> (rows: UInt16, cols: UInt16)? {
        return Terminal.windowSize(inFD) ?? Terminal.windowSize(outFD)
    }

    private func recordSignal(_ sig: Int32) {
        outcomeLock.lock()
        defer { outcomeLock.unlock() }
        guard !outcomeSet else { return }
        outcomeSet = true
        signaledWith = sig
    }

    private func teardown() {
        winchSource?.cancel()
        intSource?.cancel()
        termSource?.cancel()
        // shutdown, not close: the detached stdin pump may still be blocked and
        // could write to a recycled fd number if we freed it. The fd leaks until
        // process exit by design; the guest gets SIGHUP from the half-close.
        _ = Darwin.shutdown(dataFD, SHUT_RDWR)
    }

    /// Reap the exit code. session_wait is non-blocking, so poll it (bounded)
    /// to cover the race where the data close beats the agent's child reap.
    private func resolveOutcome() throws -> AttachOutcome {
        outcomeLock.lock()
        let sig = outcomeSet ? signaledWith : 0
        outcomeLock.unlock()
        if sig != 0 { return .signaled(sig) }
        for _ in 0..<50 {  // bounded: at most 50 * 10ms = 500ms of polling
            let waited = try control.sessionWait(sessionID: sessionID)
            guard waited.done else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            guard let code = waited.exitCode else {
                throw MSLError.protocolMismatch("session done with null exit_code")
            }
            return .exited(code)
        }
        throw MSLError.protocolMismatch("session did not report exit")
    }
}

/// Write all `count` bytes of `buffer` to `fd`; bounded by byte count (each
/// write advances >= 1 byte). Returns false on unrecoverable write error.
private func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) -> Bool {
    precondition(count >= 0, "write count must be non-negative")
    guard count > 0 else { return true }
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
