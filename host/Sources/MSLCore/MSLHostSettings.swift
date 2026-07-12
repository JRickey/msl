import CMSLSys
import Darwin
import Foundation

public struct MSLHostSettings: Codable, Sendable, Equatable {
    public var version: Int
    public var cpuCount: Int?
    public var memoryMiB: UInt64?
    public var idleTimeoutS: Int
    public var shareHome: Bool
    public var interopEnabled: Bool

    public init(
        version: Int = 1, cpuCount: Int? = nil, memoryMiB: UInt64? = nil,
        idleTimeoutS: Int = 60, shareHome: Bool = true, interopEnabled: Bool = true
    ) {
        self.version = version
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.idleTimeoutS = idleTimeoutS
        self.shareHome = shareHome
        self.interopEnabled = interopEnabled
    }

    public func applyingOverrides(
        cpuCount: Int?, memoryMiB: UInt64?, idleTimeoutS: Int?, shareHome: Bool?,
        interopEnabled: Bool?
    ) throws -> MSLHostSettings {
        var resolved = self
        if let cpuCount { resolved.cpuCount = cpuCount }
        if let memoryMiB { resolved.memoryMiB = memoryMiB }
        if let idleTimeoutS { resolved.idleTimeoutS = idleTimeoutS }
        if let shareHome { resolved.shareHome = shareHome }
        if let interopEnabled { resolved.interopEnabled = interopEnabled }
        try resolved.validate(source: "daemon overrides")
        return resolved
    }

    func validate(source: String) throws {
        precondition(!source.isEmpty, "settings source must not be empty")
        assert(1 <= 64, "CPU validation bounds must be ordered")
        assert(1024 <= 65536, "memory validation bounds must be ordered")
        guard version == 1 else {
            throw MSLError.configuration("unsupported host settings version in \(source)")
        }
        if let cpuCount, !(1...64).contains(cpuCount) {
            throw MSLError.configuration("CPU count must be 1...64 in \(source)")
        }
        if let memoryMiB, !(1024...65536).contains(memoryMiB) {
            throw MSLError.configuration("memory must be 1024...65536 MiB in \(source)")
        }
        guard (0...86400).contains(idleTimeoutS) else {
            throw MSLError.configuration("idle timeout must be 0...86400 seconds in \(source)")
        }
    }
}

public struct MSLHostSettingsStore: Sendable {
    private let url: URL
    private let lockURL: URL

    public init(home: MSLHome) {
        self.init(url: home.hostSettingsURL)
    }

    public init(url: URL) {
        precondition(url.isFileURL, "settings URL must be a file URL")
        precondition(!url.path.isEmpty, "settings URL must have a path")
        self.url = url
        self.lockURL = url.appendingPathExtension("lock")
    }

    public func load() throws -> MSLHostSettings {
        return try loadUnlocked()
    }

    public func save(_ settings: MSLHostSettings) throws {
        try withMutationLock { try saveUnlocked(settings) }
    }

    @discardableResult
    public func update(
        _ mutation: @Sendable (inout MSLHostSettings) throws -> Void
    ) throws -> MSLHostSettings {
        return try withMutationLock {
            var settings = try loadUnlocked()
            try mutation(&settings)
            try saveUnlocked(settings)
            return settings
        }
    }

    private func loadUnlocked() throws -> MSLHostSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return MSLHostSettings() }
        let data = try Data(contentsOf: url)
        let whitespace =
            String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
        guard !data.isEmpty, !whitespace else {
            throw MSLError.configuration("host settings are empty/truncated: \(url.path)")
        }
        let settings: MSLHostSettings
        do {
            settings = try JSONDecoder().decode(MSLHostSettings.self, from: data)
        } catch {
            throw MSLError.configuration("host settings are corrupt: \(error) [\(url.path)]")
        }
        try settings.validate(source: url.path)
        return settings
    }

    private func saveUnlocked(_ settings: MSLHostSettings) throws {
        try settings.validate(source: url.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try SettingsSecureFile.write(data, to: url)
    }

    private func withMutationLock<Value>(_ body: () throws -> Value) throws -> Value {
        precondition(lockURL.isFileURL, "settings lock must be a file URL")
        assert(!lockURL.path.isEmpty, "settings lock path must not be empty")
        let lock = try SettingsFileLock.acquire(at: lockURL)
        let result: Value
        do {
            result = try body()
        } catch {
            lock.releasePreservingPrimaryError()
            throw error
        }
        try lock.release()
        return result
    }
}

private final class SettingsFileLock: @unchecked Sendable {
    private static let maxAttempts = 40
    private static let retryIntervalS = 0.025
    private var fd: Int32

    private init(fd: Int32) {
        precondition(fd >= 0, "settings lock descriptor must be valid")
        self.fd = fd
    }

    deinit { releasePreservingPrimaryError() }

    static func acquire(at url: URL) throws -> SettingsFileLock {
        precondition(url.isFileURL, "settings lock must be a file URL")
        assert(!url.path.isEmpty, "settings lock path must not be empty")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw MSLError.io("cannot open settings lock \(url.path): errno=\(errno)")
        }
        guard Darwin.fchmod(fd, 0o600) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            throw MSLError.io("cannot secure settings lock \(url.path): errno=\(code)")
        }
        return try wait(fd: fd, path: url.path)
    }

    private static func wait(fd: Int32, path: String) throws -> SettingsFileLock {
        precondition(fd >= 0, "settings lock descriptor must be valid")
        precondition(!path.isEmpty, "settings lock path must not be empty")
        for attempt in 0..<maxAttempts {
            if msl_flock(fd, LOCK_EX | LOCK_NB) == 0 { return SettingsFileLock(fd: fd) }
            let code = errno
            guard code == EWOULDBLOCK else {
                _ = Darwin.close(fd)
                throw MSLError.io("flock failed for \(path): errno=\(code)")
            }
            if attempt < maxAttempts - 1 { Thread.sleep(forTimeInterval: retryIntervalS) }
        }
        _ = Darwin.close(fd)
        throw MSLError.timedOut("settings lock remained busy: \(path)")
    }

    func release() throws {
        guard fd >= 0 else { return }
        let owned = fd
        fd = -1
        let unlockResult = msl_flock(owned, LOCK_UN)
        let unlockCode = unlockResult == 0 ? 0 : errno
        let closeResult = Darwin.close(owned)
        let closeCode = closeResult == 0 ? 0 : errno
        guard unlockResult == 0 else {
            throw MSLError.io("unlock failed for settings lock: errno=\(unlockCode)")
        }
        guard closeResult == 0 else {
            throw MSLError.io("close failed for settings lock: errno=\(closeCode)")
        }
    }

    func releasePreservingPrimaryError() {
        do {
            try release()
        } catch {
            // The mutation error remains primary after cleanup has been attempted.
            let line = "msl: settings lock cleanup failed: \(error)\n"
            do {
                try FileHandle.standardError.write(contentsOf: Data(line.utf8))
            } catch {}
        }
    }
}

private enum SettingsSecureFile {
    static func write(_ data: Data, to url: URL) throws {
        precondition(!data.isEmpty, "settings data must not be empty")
        precondition(url.isFileURL, "settings URL must be a file URL")
        let temp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(Token.generate()).tmp")
        guard
            FileManager.default.createFile(
                atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw MSLError.io("cannot create settings temporary file: \(temp.path)") }
        do {
            try data.write(to: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard Darwin.rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw MSLError.io("rename \(temp.path) failed: errno=\(code)")
        }
    }
}
