import Foundation

/// A parsed commit plus its host receive timestamp, awaiting a display tick.
public struct GuiHeldCommit: Sendable {
    public let commit: GuiCommit
    public let recvNs: UInt64

    public init(commit: GuiCommit, recvNs: UInt64) {
        self.commit = commit
        self.recvNs = recvNs
    }
}

/// One window's keep-latest commit slot, shared between the reader thread (which
/// stores) and the main thread (which drains it on the display tick). A fast
/// peer never grows the queue: an un-drained commit is replaced, not appended.
public final class GuiCommitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var slot = KeepLatest<GuiHeldCommit>()

    public init() {}

    public func store(_ held: GuiHeldCommit) {
        lock.lock()
        defer { lock.unlock() }
        slot.store(held)
        assert(!slot.isEmpty, "store leaves the slot occupied")
    }

    public func take() -> GuiHeldCommit? {
        lock.lock()
        defer { lock.unlock() }
        let taken = slot.take()
        assert(slot.isEmpty, "take clears the slot")
        return taken
    }
}

/// Thread-safe win→latch registry: the reader deposits commits by window id
/// without touching main-actor window state.
public final class GuiCommitRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var latches: [UInt32: GuiCommitLatch] = [:]

    public static let maxWindows = 4096

    public init() {}

    public func register(win: UInt32, latch: GuiCommitLatch) {
        lock.lock()
        defer { lock.unlock() }
        assert(latches.count <= GuiCommitRouter.maxWindows, "window registry stays bounded")
        latches[win] = latch
    }

    public func unregister(win: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        latches.removeValue(forKey: win)
    }

    /// Deposit a commit into its window's latch; a commit for an unknown window
    /// (e.g. arriving before its `win_new` is processed) is dropped.
    public func store(win: UInt32, held: GuiHeldCommit) {
        let latch = withLock { latches[win] }
        guard let latch else { return }
        latch.store(held)
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
