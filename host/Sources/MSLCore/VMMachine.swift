import Darwin
import Foundation
import Virtualization

/// Validated boot parameters for a headless M0 VM.
public struct BootSpec: Sendable {
    public let kernelURL: URL
    public let initramfsURL: URL
    public let commandLine: String
    public let cpuCount: Int
    public let memoryMiB: UInt64
    public let consoleLogPath: String?
    public let execCommand: String?
    public let timeout: Double

    public init(
        kernelPath: String, initramfsPath: String, commandLine: String,
        cpuCount: Int, memoryMiB: UInt64, consoleLogPath: String?,
        execCommand: String?, timeout: Double
    ) throws {
        guard cpuCount >= 1 else { throw MSLError.invalidArgument("cpus must be >= 1") }
        guard memoryMiB >= 1 else { throw MSLError.invalidArgument("memory-mib must be >= 1") }
        guard timeout > 0 else { throw MSLError.invalidArgument("timeout must be > 0") }
        guard !commandLine.isEmpty else { throw MSLError.invalidArgument("cmdline is empty") }
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: kernelPath) else {
            throw MSLError.invalidArgument("kernel not readable: \(kernelPath)")
        }
        guard fileManager.isReadableFile(atPath: initramfsPath) else {
            throw MSLError.invalidArgument("initramfs not readable: \(initramfsPath)")
        }
        self.kernelURL = URL(fileURLWithPath: kernelPath)
        self.initramfsURL = URL(fileURLWithPath: initramfsPath)
        self.commandLine = commandLine
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.consoleLogPath = consoleLogPath
        self.execCommand = execCommand
        self.timeout = timeout
    }
}

/// Mutable reference passed into VZ completion handlers; reads and writes are
/// serialized by the DispatchSemaphore handshake in each blocking method.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Per-attempt connect coordinator. `resolved` and `fd` are mutated only on
/// the VM queue; whichever of the completion or the timeout path reaches the
/// queue first owns the outcome, so a late completion cannot store a stale fd.
final class ConnectAttempt: @unchecked Sendable {
    var resolved = false
    var fd: Int32 = -1
    let semaphore = DispatchSemaphore(value: 0)
}

/// Delegate for VM stop notifications; callbacks arrive on the VM queue.
final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    let onStop: @Sendable (Error?) -> Void

    init(onStop: @escaping @Sendable (Error?) -> Void) {
        self.onStop = onStop
        super.init()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStop(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStop(error)
    }
}

/// Owns the VZVirtualMachine and every object touched on the private serial
/// queue. `@unchecked Sendable`: all mutable state below is read and written
/// only inside `queue`-confined closures; callers reach it through the
/// blocking methods, which hop onto `queue` and wait on a semaphore.
public final class VMHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "msl.vm", qos: .userInitiated)
    private let connectAttemptTimeoutMs = 750
    private let spec: BootSpec
    private var consoleHandle: FileHandle?
    private var resolvedConsolePath: String?
    private var machine: VZVirtualMachine?
    private var delegate: VMDelegate?
    private var stopRequested = false

    public init(spec: BootSpec) {
        self.spec = spec
    }

    /// Path of the console-log file (explicit or the generated temp path).
    public var consolePath: String? { resolvedConsolePath }

    /// Build the VM, start it, and block until start succeeds or fails. `onStop`
    /// receives the stop error (if any) and whether the stop was host-requested.
    public func startAndWait(onStop: @escaping @Sendable (Error?, Bool) -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<Error?>(nil)
        queue.async {
            do {
                let config = try self.makeConfiguration()
                try config.validate()
                let delegate = VMDelegate(onStop: { error in onStop(error, self.stopRequested) })
                let vm = VZVirtualMachine(configuration: config, queue: self.queue)
                vm.delegate = delegate
                self.delegate = delegate
                self.machine = vm
                vm.start { result in
                    if case .failure(let error) = result {
                        box.value = MSLError.fromVZ("VZVirtualMachine.start", error)
                    }
                    semaphore.signal()
                }
            } catch {
                box.value = error
                semaphore.signal()
            }
        }
        semaphore.wait()
        if let error = box.value { throw error }
    }

    /// Poll-connect to the agent port; each attempt is time-bounded and the
    /// whole poll is bounded by `spec.timeout` (wall clock and attempt count).
    public func connectAndWait() throws -> VsockClient {
        let interval = 0.25
        let deadline = Date().addingTimeInterval(spec.timeout)
        let maxAttempts = max(1, Int((spec.timeout / interval).rounded(.up)) + 1)
        for _ in 0..<maxAttempts {  // bounded loop: attempts derived from --timeout
            if let fd = connectOnce(), fd >= 0 {
                return try VsockClient(fileDescriptor: fd)
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: interval)
        }
        throw MSLError.timedOut("vsock port \(Proto.port) after \(spec.timeout)s")
    }

    /// Force-stop the VM and block until the stop completes; returns the wrapped
    /// VZ error if the stop itself failed, `nil` on success.
    public func stopAndWait() -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<Error?>(nil)
        queue.async {
            self.stopRequested = true
            guard let vm = self.machine, vm.canStop else {
                semaphore.signal()
                return
            }
            vm.stop { error in
                if let error {
                    box.value = MSLError.fromVZ("VZVirtualMachine.stop", error)
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value
    }

    private func connectOnce() -> Int32? {
        let attempt = ConnectAttempt()
        queue.async { self.startConnect(attempt) }
        let waited = attempt.semaphore.wait(
            timeout: .now() + .milliseconds(connectAttemptTimeoutMs))
        if waited == .timedOut {
            return resolveTimedOut(attempt)
        }
        return attempt.fd >= 0 ? attempt.fd : nil
    }

    private func startConnect(_ attempt: ConnectAttempt) {
        guard let vm = self.machine,
            let device = vm.socketDevices.first as? VZVirtioSocketDevice
        else {
            attempt.resolved = true
            attempt.semaphore.signal()
            return
        }
        device.connect(toPort: Proto.port) { result in
            guard !attempt.resolved else {
                if case .success(let conn) = result { conn.close() }
                return
            }
            attempt.resolved = true
            if case .success(let conn) = result {
                attempt.fd = Darwin.dup(conn.fileDescriptor)
                conn.close()
            }
            attempt.semaphore.signal()
        }
    }

    private func resolveTimedOut(_ attempt: ConnectAttempt) -> Int32? {
        var fd: Int32 = -1
        queue.sync {
            if !attempt.resolved { attempt.resolved = true }
            fd = attempt.fd
        }
        return fd >= 0 ? fd : nil
    }

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let loader = VZLinuxBootLoader(kernelURL: spec.kernelURL)
        loader.initialRamdiskURL = spec.initramfsURL
        loader.commandLine = spec.commandLine

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = loader
        config.cpuCount = clampCPU(spec.cpuCount)
        config.memorySize = clampMemory(spec.memoryMiB)
        config.serialPorts = [try makeConsole()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]
        return config
    }

    private func makeConsole() throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        let path = try resolveConsolePath()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            guard fileManager.createFile(atPath: path, contents: nil) else {
                throw MSLError.io("cannot create console log: \(path)")
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw MSLError.io("cannot open console log for writing: \(path)")
        }
        self.consoleHandle = handle
        self.resolvedConsolePath = path
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: handle)
        return serial
    }

    private func resolveConsolePath() throws -> String {
        if let explicit = spec.consoleLogPath {
            guard !explicit.isEmpty else { throw MSLError.invalidArgument("empty console path") }
            return explicit
        }
        let name = "msl-console-\(UUID().uuidString).log"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name).path
    }

    private func clampCPU(_ requested: Int) -> Int {
        assert(requested >= 1, "cpu request validated by BootSpec")
        let low = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let high = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        return min(max(requested, low), high)
    }

    private func clampMemory(_ mib: UInt64) -> UInt64 {
        assert(mib >= 1, "memory request validated by BootSpec")
        let bytes = mib &* 1024 &* 1024
        let low = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let high = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        return min(max(bytes, low), high)
    }
}
