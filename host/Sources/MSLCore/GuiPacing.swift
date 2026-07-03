import Foundation

/// Per-window frame pacing (protocol pipeline rule): at most one un-acked
/// present outstanding, and commits arriving before the next tick coalesce to
/// the latest. Pure value type so the pacing decision is unit-testable off the
/// display link.
public struct GuiPacer: Sendable, Equatable {
    private var latestPending: UInt32?
    private var unacked: Bool

    public init() {
        self.latestPending = nil
        self.unacked = false
    }

    public enum Tick: Sendable, Equatable {
        case present(UInt32)
        case hold
    }

    public var hasPending: Bool { latestPending != nil }
    public var isUnacked: Bool { unacked }

    /// Record a freshly received commit; a still-pending earlier commit is
    /// dropped in favor of this newer sequence (coalescing).
    public mutating func onCommit(seq: UInt32) {
        latestPending = seq
        assert(latestPending == seq, "pending must hold the latest committed seq")
        assert(hasPending, "a commit was just recorded")
    }

    /// Decide what to present on a display-link tick: nothing while a prior
    /// present is un-acked, otherwise the latest pending commit (if any).
    public mutating func tick() -> Tick {
        guard !unacked else {
            assert(latestPending == nil || hasPending, "hold leaves pending intact")
            return .hold
        }
        guard let seq = latestPending else { return .hold }
        latestPending = nil
        unacked = true
        assert(unacked && !hasPending, "presenting consumes the pending commit")
        return .present(seq)
    }

    /// Release the pipeline: the presented frame's ack has been emitted.
    public mutating func onAck() {
        unacked = false
        assert(!isUnacked, "ack clears the outstanding present")
    }
}

/// Single-slot keep-latest holder: `store` replaces any un-taken value, so a
/// producer faster than the consumer never queues work — only the newest value
/// survives to be taken. Pure; the concurrent wrapper adds locking.
public struct KeepLatest<Value: Sendable>: Sendable {
    private var value: Value?

    public init() { self.value = nil }

    public var isEmpty: Bool { value == nil }

    public mutating func store(_ newValue: Value) {
        value = newValue
        assert(!isEmpty, "store leaves a value present")
    }

    public mutating func take() -> Value? {
        let taken = value
        value = nil
        assert(isEmpty, "take clears the slot")
        return taken
    }
}

/// One presented-commit measurement (host clocks in monotonic ns).
public struct GuiCommitSample: Sendable, Equatable {
    public let win: UInt32
    public let seq: UInt32
    public let tRecvNs: UInt64
    public let tPresentNs: UInt64
    public let tClientCommitNs: UInt64
    public let tSendNs: UInt64

    public init(
        win: UInt32, seq: UInt32, tRecvNs: UInt64, tPresentNs: UInt64,
        tClientCommitNs: UInt64, tSendNs: UInt64
    ) {
        self.win = win
        self.seq = seq
        self.tRecvNs = tRecvNs
        self.tPresentNs = tPresentNs
        self.tClientCommitNs = tClientCommitNs
        self.tSendNs = tSendNs
    }

    /// Host-observed commit→present latency (0 if the present preceded recv).
    public var commitToPresentNs: UInt64 { tPresentNs >= tRecvNs ? tPresentNs - tRecvNs : 0 }
}

/// One input-event measurement: the event's send instant and the first present
/// that followed it on the same window.
public struct GuiInputSample: Sendable, Equatable {
    public let win: UInt32
    public let kind: String
    public let tInputNs: UInt64
    public let tPresentNs: UInt64

    public init(win: UInt32, kind: String, tInputNs: UInt64, tPresentNs: UInt64) {
        self.win = win
        self.kind = kind
        self.tInputNs = tInputNs
        self.tPresentNs = tPresentNs
    }

    /// Host-observed input→present latency (0 if present preceded the input).
    public var inputToPresentNs: UInt64 { tPresentNs >= tInputNs ? tPresentNs - tInputNs : 0 }
}

/// Bounded ring ledger of commit and input samples plus pure percentile/CSV
/// rendering for the gate report. Owned single-threaded by the presenter.
public struct GuiLedger: Sendable {
    public static let capacity = 8192

    private var commits: [GuiCommitSample] = []
    private var inputs: [GuiInputSample] = []

    public init() {
        commits.reserveCapacity(GuiLedger.capacity)
        inputs.reserveCapacity(GuiLedger.capacity)
    }

    public var commitCount: Int { commits.count }
    public var inputCount: Int { inputs.count }

    public mutating func addCommit(_ sample: GuiCommitSample) {
        assert(commits.count <= GuiLedger.capacity, "commit ring stays bounded")
        if commits.count >= GuiLedger.capacity { commits.removeFirst() }
        commits.append(sample)
    }

    public mutating func addInput(_ sample: GuiInputSample) {
        assert(inputs.count <= GuiLedger.capacity, "input ring stays bounded")
        if inputs.count >= GuiLedger.capacity { inputs.removeFirst() }
        inputs.append(sample)
    }

    public func commitToPresent(_ percentile: Double) -> UInt64? {
        return GuiLedger.percentile(commits.map { $0.commitToPresentNs }, percentile)
    }

    public func inputToPresent(_ percentile: Double) -> UInt64? {
        return GuiLedger.percentile(inputs.map { $0.inputToPresentNs }, percentile)
    }

    /// Nearest-rank percentile of an unsorted sample set; nil when empty.
    public static func percentile(_ values: [UInt64], _ fraction: Double) -> UInt64? {
        precondition(fraction >= 0 && fraction <= 1, "percentile fraction in [0,1]")
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        assert(index >= 0 && index < sorted.count, "percentile index in range")
        return sorted[index]
    }

    /// Render every sample as CSV rows (one header line, commit rows, input rows).
    public func csv() -> String {
        var lines = ["kind,win,seq_or_kind,t_a_ns,t_present_ns,t_client_ns,t_send_ns,delta_ns"]
        lines.reserveCapacity(commits.count + inputs.count + 1)
        for sample in commits {  // bounded: ≤ capacity
            lines.append(
                "commit,\(sample.win),\(sample.seq),\(sample.tRecvNs),\(sample.tPresentNs),"
                    + "\(sample.tClientCommitNs),\(sample.tSendNs),\(sample.commitToPresentNs)")
        }
        for sample in inputs {  // bounded: ≤ capacity
            lines.append(
                "input,\(sample.win),\(sample.kind),\(sample.tInputNs),\(sample.tPresentNs),,,"
                    + "\(sample.inputToPresentNs)")
        }
        assert(lines.count >= 1, "csv always has a header line")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One-line p50/p95 summary for stdout on exit.
    public func summary() -> String {
        let c50 = commitToPresent(0.50).map(GuiLedger.ms) ?? "n/a"
        let c95 = commitToPresent(0.95).map(GuiLedger.ms) ?? "n/a"
        let i50 = inputToPresent(0.50).map(GuiLedger.ms) ?? "n/a"
        let i95 = inputToPresent(0.95).map(GuiLedger.ms) ?? "n/a"
        return "commit→present p50=\(c50) p95=\(c95); input→present p50=\(i50) p95=\(i95) "
            + "(\(commits.count) commits, \(inputs.count) inputs)"
    }

    private static func ms(_ ns: UInt64) -> String {
        return String(format: "%.2fms", Double(ns) / 1_000_000.0)
    }
}
