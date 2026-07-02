import Darwin
import Foundation

/// Drives the M0 boot flow off the VM's serial queue: start, poll-connect,
/// ping, optional exec, then stop. `exit(_:)` is the sanctioned termination
/// point for the CLI (never `fatalError`). `@unchecked Sendable`: the only
/// mutable field is set once during `launch()` before any concurrent use.
public final class Driver: @unchecked Sendable {
    private let host: VMHost
    private let spec: BootSpec
    private let driverQueue = DispatchQueue(label: "msl.driver", qos: .userInitiated)
    private let signalQueue = DispatchQueue(label: "msl.signal", qos: .userInitiated)
    private var signalSource: DispatchSourceSignal?

    public init(host: VMHost, spec: BootSpec) {
        self.host = host
        self.spec = spec
    }

    /// Install the SIGINT handler and kick the boot sequence; returns so the
    /// caller can enter `dispatchMain()`.
    public func launch() {
        installSignalHandler()
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
            write(line: "console log: \(path)", to: FileHandle.standardError)
        }
        let client = connectOrExit()
        do {
            try ping(client)
        } catch {
            reportAndExit(error, code: 1)
        }
        guard let command = spec.execCommand else {
            return  // stay booted until SIGINT; signal handler stops and exits
        }
        exec(client, command: command)
    }

    private func connectOrExit() -> VsockClient {
        do {
            return try host.connectAndWait()
        } catch {
            reportAndExit(error, code: 1)
        }
    }

    private func ping(_ client: VsockClient) throws {
        let request = Request.ping(id: 1)
        try client.send(try request.encoded())
        let payload = try client.receive()
        let response = try Response<PingData>.decode(payload, expectedID: 1)
        guard response.ok else {
            throw MSLError.protocolMismatch("ping failed: \(response.error ?? "unknown")")
        }
        write(raw: payload, to: FileHandle.standardOutput)
        write(line: "", to: FileHandle.standardOutput)
    }

    private func exec(_ client: VsockClient, command: String) -> Never {
        assert(!command.isEmpty, "exec command validated by caller")
        do {
            let request = Request.exec(
                id: 2, argv: ["/bin/sh", "-c", command], env: nil, timeoutMs: 30000)
            try client.send(try request.encoded())
            let payload = try client.receive()
            let response = try Response<ExecData>.decode(payload, expectedID: 2)
            guard response.ok, let data = response.data else {
                let reason = response.error ?? "unknown"
                write(line: "msl: exec failed: \(reason)", to: FileHandle.standardError)
                _ = host.stopAndWait()
                exit(1)
            }
            write(raw: Data(data.stdout.utf8), to: FileHandle.standardOutput)
            write(raw: Data(data.stderr.utf8), to: FileHandle.standardError)
            if let stopError = host.stopAndWait() {
                write(line: "msl: stop error: \(describe(stopError))", to: FileHandle.standardError)
            }
            exit(data.exitCode)
        } catch {
            reportAndExit(error, code: 1)
        }
    }

    private func handleStop(_ error: Error?, requested: Bool) {
        guard !requested else { return }  // the requesting path owns the exit
        let reason = error.map { MSLError.fromVZ("guest stop", $0).description } ?? "guest exited"
        let message = "msl: virtual machine stopped unexpectedly (\(reason))"
        write(line: message, to: FileHandle.standardError)
        exit(1)
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        source.setEventHandler { [weak self] in
            guard let self else { exit(0) }
            if let stopError = self.host.stopAndWait() {
                self.write(line: "msl: \(self.describe(stopError))", to: FileHandle.standardError)
                exit(1)
            }
            exit(0)
        }
        source.resume()
        self.signalSource = source
    }

    private func reportAndExit(_ error: Error, code: Int32) -> Never {
        write(line: "msl: \(describe(error))", to: FileHandle.standardError)
        _ = host.stopAndWait()
        exit(code)
    }

    private func describe(_ error: Error) -> String {
        (error as? MSLError)?.description ?? error.localizedDescription
    }

    private func write(raw data: Data, to handle: FileHandle) {
        guard !data.isEmpty else { return }
        try? handle.write(contentsOf: data)
    }

    private func write(line: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
