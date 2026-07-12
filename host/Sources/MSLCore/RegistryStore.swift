import CMSLSys
import Darwin
import Foundation

/// Serializes registry read-modify-write transactions across msl processes.
public struct RegistryStore: Sendable {
    private let home: MSLHome

    public init(home: MSLHome) {
        precondition(!home.root.path.isEmpty, "MSL home path must not be empty")
        self.home = home
    }

    public func load() throws -> Registry {
        assert(lockURL != home.registryURL, "registry data and lock paths must differ")
        return try withLock(operation: LOCK_SH) {
            try Registry.load(from: home.registryURL)
        }
    }

    /// The body runs under the exclusive lock and must stay bounded to in-memory mutation.
    public func update(
        _ body: (inout Registry) throws -> Void
    ) throws -> Registry {
        assert(lockURL != home.registryURL, "registry data and lock paths must differ")
        return try withLock(operation: LOCK_EX) {
            var registry = try Registry.load(from: home.registryURL)
            try body(&registry)
            let encoded = try JSONEncoder().encode(registry)
            assert(!encoded.isEmpty, "encoded registry must contain data")
            guard !encoded.isEmpty else {
                throw MSLError.configuration("cannot encode an empty registry")
            }
            try registry.save(to: home.registryURL)
            return registry
        }
    }

    // Atomic registry saves replace the data inode, so the lock needs a stable sidecar.
    private var lockURL: URL {
        home.registryURL.appendingPathExtension("lock")
    }

    private func withLock<T>(
        operation: Int32,
        _ body: () throws -> T
    ) throws -> T {
        assert(
            operation == LOCK_SH || operation == LOCK_EX,
            "lock mode must be shared or exclusive"
        )
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw MSLError.io("cannot open registry lock: errno=\(errno) [\(lockURL.path)]")
        }
        let lockResult = msl_flock(descriptor, operation)
        guard lockResult == 0 else {
            let lockError = errno
            let closeResult = Darwin.close(descriptor)
            let closeError = closeResult == 0 ? nil : errno
            throw MSLError.io(lockFailure(lockError: lockError, closeError: closeError))
        }
        let result: T
        do {
            result = try body()
        } catch {
            let bodyError = error
            if releaseLock(descriptor) != nil { throw bodyError }
            throw bodyError
        }
        if let cleanupFailure = releaseLock(descriptor) {
            throw MSLError.io(cleanupFailure)
        }
        return result
    }

    private func releaseLock(_ descriptor: Int32) -> String? {
        assert(descriptor >= 0, "lock descriptor must be valid")
        let unlockResult = msl_flock(descriptor, LOCK_UN)
        let unlockError = unlockResult == 0 ? nil : errno
        let closeResult = Darwin.close(descriptor)
        let closeError = closeResult == 0 ? nil : errno
        switch (unlockError, closeError) {
        case (nil, nil): return nil
        case (.some(let code), nil): return "cannot unlock registry: errno=\(code)"
        case (nil, .some(let code)): return "cannot close registry lock: errno=\(code)"
        case (.some(let unlock), .some(let close)):
            return "cannot unlock registry: errno=\(unlock); cannot close lock: errno=\(close)"
        }
    }

    private func lockFailure(lockError: Int32, closeError: Int32?) -> String {
        let base = "cannot lock registry: errno=\(lockError) [\(lockURL.path)]"
        guard let closeError else { return base }
        return "\(base); cannot close failed lock descriptor: errno=\(closeError)"
    }
}
