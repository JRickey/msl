import Darwin
import Foundation

/// Options for the `msl up` flow that are not part of the VM boot spec.
public struct UpConfig: Sendable {
    public let hostname: String
    public let shell: Bool
    public let shellArgv: [String]
    public let home: String
    public let hostCwd: String
    public let term: String

    public init(
        hostname: String, shell: Bool, shellArgv: [String], home: String, hostCwd: String,
        term: String
    ) {
        precondition(!hostname.isEmpty, "hostname must not be empty")
        precondition(!shellArgv.isEmpty, "shell argv must not be empty")
        self.hostname = hostname
        self.shell = shell
        self.shellArgv = shellArgv
        self.home = home
        self.hostCwd = hostCwd
        self.term = term
    }
}

/// Drives `msl up`: boot -> ping -> distro_up -> set_time, then either an
/// attached interactive shell (shut the VM down on exit) or resident daemon
/// mode. This process is the M1 daemon. `@unchecked Sendable`: mutable fields
/// are set once during `launch()` before concurrent use.
public final class UpDriver: @unchecked Sendable {
    private let host: VMHost
    private let spec: BootSpec
    private let config: UpConfig
    private let driverQueue = DispatchQueue(label: "msl.up.driver", qos: .userInitiated)
    private let signalQueue = DispatchQueue(label: "msl.up.signal", qos: .userInitiated)
    private var control: ControlClient?
    private var powerWake: PowerWake?
    private var signalSource: DispatchSourceSignal?

    public init(host: VMHost, spec: BootSpec, config: UpConfig) {
        self.host = host
        self.spec = spec
        self.config = config
    }

    /// Kick the boot sequence on a background queue; the caller enters
    /// `dispatchMain()` so the process stays alive as the daemon.
    public func launch() {
        driverQueue.async { self.drive() }
    }

    private func drive() {
        do {
            try host.startAndWait(onStop: { [weak self] error, requested in
                self?.handleStop(error, requested: requested)
            })
        } catch {
            reportAndExit(error, code: 1)
        }
        if let path = host.consolePath {
            write(line: "msl: console log: \(path)", to: FileHandle.standardError)
        }
        let control = connectControlOrExit()
        self.control = control
        bringUp(control)
        write(line: "msl: distro running", to: FileHandle.standardError)
        if config.shell {
            runShell(control)
        }
        installResidentSignalHandler()
    }

    private func bringUp(_ control: ControlClient) {
        do {
            _ = try control.ping()
            let macShare = spec.shares.contains { $0.tag == "mac" }
            _ = try control.distroUp(
                dev: "/dev/vda", hostname: config.hostname, macShare: macShare)
        } catch {
            reportAndExit(error, code: 1)
        }
        syncTime(control)
        startPowerWake(control)
    }

    private func runShell(_ control: ControlClient) -> Never {
        do {
            let outcome = try openAndAttach(control)
            _ = host.stopAndWait()
            switch outcome {
            case .exited(let code): exit(code)
            case .signaled(let sig): exit(128 &+ sig)
            }
        } catch {
            reportAndExit(error, code: 1)
        }
    }

    private func openAndAttach(_ control: ControlClient) throws -> AttachOutcome {
        let macShare = spec.shares.contains { $0.tag == "mac" }
        let cwd = mapSessionCwd(hostCwd: config.hostCwd, home: config.home, hasMacShare: macShare)
        let size = Terminal.windowSize(STDIN_FILENO) ?? Terminal.windowSize(STDOUT_FILENO)
        let open = SessionOpenReq(
            argv: config.shellArgv, cwd: cwd, env: ["TERM": config.term],
            rows: size?.rows ?? 40, cols: size?.cols ?? 120, distro: true)
        let opened = try control.sessionOpen(open)
        let dataFD = try handshakeData(sessionID: opened.sessionID, token: opened.token)
        return try SessionAttach(
            control: control, sessionID: opened.sessionID, dataFD: dataFD
        ).run()
    }

    private func handshakeData(sessionID: UInt64, token: String) throws -> Int32 {
        let fd = try host.connectRaw(port: Proto.dataPort, timeout: min(spec.timeout, 15))
        let framed = try VsockClient(fileDescriptor: fd)
        try framed.setReceiveTimeout(seconds: min(spec.timeout, 15))
        try framed.send(try DataHandshake(sessionID: sessionID, token: token).encoded())
        let reply = try DataHandshakeReply.decode(try framed.receive())
        guard reply.ok else {
            framed.close()
            throw MSLError.protocolMismatch("data handshake rejected: \(reply.error ?? "unknown")")
        }
        return framed.detachDescriptor()
    }

    private func syncTime(_ control: ControlClient) {
        let now = Date().timeIntervalSince1970
        let sec = Int64(now.rounded(.down))
        let usec = Int64((now - now.rounded(.down)) * 1_000_000)
        do {
            try control.setTime(sec: sec, usec: usec)
        } catch {
            write(line: "msl: set_time failed: \(describe(error))", to: FileHandle.standardError)
        }
    }

    private func startPowerWake(_ control: ControlClient) {
        let wake = PowerWake(onWake: { [weak self] in self?.syncTime(control) })
        wake.start()
        self.powerWake = wake
    }

    private func handleStop(_ error: Error?, requested: Bool) {
        guard !requested else { return }
        let reason = error.map { MSLError.fromVZ("guest stop", $0).description } ?? "guest exited"
        write(
            line: "msl: virtual machine stopped unexpectedly (\(reason))",
            to: FileHandle.standardError)
        exit(1)
    }

    private func installResidentSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        source.setEventHandler { [weak self] in
            guard let self else { exit(0) }
            _ = self.host.stopAndWait()
            exit(0)
        }
        source.resume()
        self.signalSource = source
    }

    private func connectControlOrExit() -> ControlClient {
        do {
            return try ControlClient(client: try host.connectAndWait())
        } catch {
            reportAndExit(error, code: 1)
        }
    }

    private func reportAndExit(_ error: Error, code: Int32) -> Never {
        write(line: "msl: \(describe(error))", to: FileHandle.standardError)
        _ = host.stopAndWait()
        exit(code)
    }

    private func describe(_ error: Error) -> String {
        (error as? MSLError)?.description ?? error.localizedDescription
    }

    private func write(line: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
