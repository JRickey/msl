import Foundation

/// Lifecycle phase of one FSKit mount.
public enum FSMountPhase: String, Sendable, Equatable, Codable {
    /// The daemon minted a mount id + nonce; macOS has not mounted yet.
    case prepared
    /// macOS mounted the volume; the mount holds an activity reference.
    case mounted
    /// The backing VM/guest died under a live mount; ops return ENODEV/EIO.
    case failed
}

/// One mount's record: routing identity, mountpoint, phase, and whether the
/// single-use nonce has been consumed by a successful appex route.
public struct FSMountRecord: Sendable, Equatable {
    public let name: String
    public let mountID: String
    public let nonce: String
    public let mountpoint: String
    public let readonly: Bool
    public var phase: FSMountPhase
    public var nonceConsumed: Bool

    public init(
        name: String, mountID: String, nonce: String, mountpoint: String, readonly: Bool,
        phase: FSMountPhase = .prepared, nonceConsumed: Bool = false
    ) {
        precondition(!name.isEmpty, "mount name must not be empty")
        precondition(!mountID.isEmpty, "mount id must not be empty")
        self.name = name
        self.mountID = mountID
        self.nonce = nonce
        self.mountpoint = mountpoint
        self.readonly = readonly
        self.phase = phase
        self.nonceConsumed = nonceConsumed
    }
}

/// The daemon's live mount registry: one record per distro. Lock-guarded so the
/// appex-admission threads, the CLI request threads, and the lifecycle queue can
/// all touch it. Pure state — no I/O, so it is exercised directly in tests.
public final class FSMountTable: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: FSMountRecord] = [:]

    public init() {}

    /// Mint a fresh mount id + nonce for `name` and record a prepared mount,
    /// replacing any prior record for the same distro. Returns the new record.
    public func prepare(name: String, mountpoint: String, readonly: Bool) -> FSMountRecord {
        precondition(!name.isEmpty, "mount name must not be empty")
        precondition(!mountpoint.isEmpty, "mountpoint must not be empty")
        let record = FSMountRecord(
            name: name, mountID: Token.generate(), nonce: Token.generate(),
            mountpoint: mountpoint, readonly: readonly)
        lock.lock()
        defer { lock.unlock() }
        records[name] = record
        return record
    }

    /// Validate and consume the single-use nonce for an appex route. Succeeds
    /// only when a prepared record matches the distro, mount id, and nonce and
    /// the nonce is unused; marks it consumed so a replay cannot re-route.
    public func consumeNonce(distro: String, mountID: String, nonce: String) -> Bool {
        guard !distro.isEmpty, !mountID.isEmpty, !nonce.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[distro], !record.nonceConsumed else { return false }
        guard Token.matches(record.mountID, mountID), Token.matches(record.nonce, nonce) else {
            return false
        }
        record.nonceConsumed = true
        records[distro] = record
        return true
    }

    /// Transition a prepared mount to mounted after macOS mounts it. Fails if the
    /// distro is unknown or the mountpoint does not match what was prepared.
    public func commit(name: String, mountpoint: String) throws {
        precondition(!name.isEmpty, "mount name must not be empty")
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[name] else {
            throw MSLError.configuration("no prepared mount for '\(name)'")
        }
        guard record.mountpoint == mountpoint else {
            throw MSLError.configuration("mountpoint mismatch for '\(name)'")
        }
        record.phase = .mounted
        records[name] = record
    }

    /// Drop a mount from the table (unmount / teardown). Returns the prior record.
    @discardableResult
    public func remove(name: String) -> FSMountRecord? {
        precondition(!name.isEmpty, "mount name must not be empty")
        lock.lock()
        defer { lock.unlock() }
        return records.removeValue(forKey: name)
    }

    /// Mark every live mount failed (unexpected VM stop). Subsequent ops error.
    public func markAllFailed() {
        lock.lock()
        defer { lock.unlock() }
        for key in records.keys {  // bounded: <=26 distros
            records[key]?.phase = .failed
        }
    }

    /// Remove and return every record (planned teardown). Sorted by name.
    public func removeAll() -> [FSMountRecord] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(records.values).sorted { $0.name < $1.name }
        records.removeAll()
        return all
    }

    public func record(name: String) -> FSMountRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[name]
    }

    public func entries() -> [FSMountRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(records.values).sorted { $0.name < $1.name }
    }

    /// Names of mounts macOS has actually mounted (phase == .mounted), used when
    /// a live mount count must block idle VM shutdown.
    public func mountedNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.filter { $0.phase == .mounted }.map { $0.name }.sorted()
    }
}
