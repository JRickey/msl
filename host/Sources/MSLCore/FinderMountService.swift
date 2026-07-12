import Foundation
import MSLFSWire

public struct FinderMountProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stderr: String

    public init(status: Int32, stderr: String) {
        self.status = status
        self.stderr = stderr
    }
}

public protocol FinderMountProcessRunning: Sendable {
    func run(executable: String, arguments: [String]) -> FinderMountProcessResult
}

public struct FinderMountCleanupError: Error, LocalizedError, CustomStringConvertible {
    public let primaryError: any Error
    public let cleanupError: any Error

    public init(primaryError: any Error, cleanupError: any Error) {
        self.primaryError = primaryError
        self.cleanupError = cleanupError
    }

    public var errorDescription: String? {
        return description
    }

    public var description: String {
        return "\(primaryError); forced mount cleanup also failed: \(cleanupError)"
    }
}

public struct SystemFinderMountProcessRunner: FinderMountProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) -> FinderMountProcessResult {
        precondition(!executable.isEmpty, "executable path must not be empty")
        assert(executable.hasPrefix("/"), "system executable path must be absolute")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return FinderMountProcessResult(
                status: -1, stderr: "spawn \(executable) failed: \(error)")
        }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        return FinderMountProcessResult(
            status: process.terminationStatus,
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct FinderMountService: Sendable {
    private let processRunner: any FinderMountProcessRunning
    private let daemon: any FinderMountDaemon
    private let createDirectory: @Sendable (String) throws -> Void

    public init(
        processRunner: any FinderMountProcessRunning = SystemFinderMountProcessRunner()
    ) {
        self.processRunner = processRunner
        self.daemon = LiveFinderMountDaemon()
        self.createDirectory = { path in
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
        }
    }

    init(
        processRunner: any FinderMountProcessRunning, daemon: any FinderMountDaemon,
        createDirectory: @escaping @Sendable (String) throws -> Void
    ) {
        self.processRunner = processRunner
        self.daemon = daemon
        self.createDirectory = createDirectory
    }

    public func mount(
        home: MSLHome, name: String?, readOnly: Bool
    ) throws -> MountEntry {
        precondition(home.root.isFileURL, "MSL home must be a file URL")
        assert(name.map { !$0.isEmpty } ?? true, "distro name must not be empty when present")
        let prepared = try daemon.prepare(home: home, name: name, readOnly: readOnly)
        do {
            try createDirectory(prepared.mountpoint)
            let result = processRunner.run(
                executable: "/sbin/mount",
                arguments: ["-F", "-t", FSProto.shortName, prepared.url, prepared.mountpoint])
            guard result.status == 0 else {
                throw MSLError.io(
                    "mount -F failed (exit \(result.status)): \(result.stderr)")
            }
            try daemon.commit(
                home: home, name: prepared.name, mountpoint: prepared.mountpoint)
        } catch {
            if let cleanupError = cleanupPreparedMount(home: home, name: prepared.name) {
                throw FinderMountCleanupError(
                    primaryError: error, cleanupError: cleanupError)
            }
            throw error
        }
        return MountEntry(name: prepared.name, mountpoint: prepared.mountpoint, state: "mounted")
    }

    @discardableResult
    public func unmount(
        home: MSLHome, name: String?, force: Bool
    ) throws -> MountEntry {
        precondition(home.root.isFileURL, "MSL home must be a file URL")
        assert(name.map { !$0.isEmpty } ?? true, "distro name must not be empty when present")
        let mounts = try daemon.status(home: home).mounts
        let entry = try Self.resolveMount(name: name, mounts: mounts)
        let arguments = force ? ["-f", entry.mountpoint] : [entry.mountpoint]
        let result = processRunner.run(executable: "/sbin/umount", arguments: arguments)
        if result.status != 0 && !force {
            throw MSLError.io("umount failed (exit \(result.status)): \(result.stderr)")
        }
        try daemon.unmount(home: home, name: entry.name, force: force)
        return entry
    }

    private func cleanupPreparedMount(home: MSLHome, name: String) -> (any Error)? {
        do {
            try daemon.unmount(home: home, name: name, force: true)
            return nil
        } catch {
            return error
        }
    }

    private static func resolveMount(name: String?, mounts: [MountEntry]) throws -> MountEntry {
        assert(mounts.allSatisfy { !$0.name.isEmpty }, "mount names must not be empty")
        assert(mounts.allSatisfy { !$0.mountpoint.isEmpty }, "mountpoints must not be empty")
        guard !mounts.isEmpty else { throw MSLError.configuration("no distro is mounted") }
        if let name {
            guard let match = mounts.first(where: { $0.name == name }) else {
                throw MSLError.configuration("'\(name)' is not mounted")
            }
            return match
        }
        guard mounts.count == 1, let only = mounts.first else {
            let names = mounts.map { $0.name }.joined(separator: ", ")
            throw MSLError.configuration("multiple distros mounted (\(names)); name one")
        }
        return only
    }
}

protocol FinderMountDaemon: Sendable {
    func prepare(home: MSLHome, name: String?, readOnly: Bool) throws -> MountPrepareData
    func commit(home: MSLHome, name: String, mountpoint: String) throws
    func unmount(home: MSLHome, name: String, force: Bool) throws
    func status(home: MSLHome) throws -> MountStatusData
}

private struct LiveFinderMountDaemon: FinderMountDaemon {
    func prepare(home: MSLHome, name: String?, readOnly: Bool) throws -> MountPrepareData {
        return try DaemonClient.mountPrepare(home, name: name, readonly: readOnly)
    }

    func commit(home: MSLHome, name: String, mountpoint: String) throws {
        try DaemonClient.mountCommit(home, name: name, mountpoint: mountpoint)
    }

    func unmount(home: MSLHome, name: String, force: Bool) throws {
        try DaemonClient.mountUnmount(home, name: name, force: force)
    }

    func status(home: MSLHome) throws -> MountStatusData {
        return try DaemonClient.mountStatus(home)
    }
}
