import Foundation

/// Pure balloon-target policy for the daemon poll tick. No I/O: every decision
/// is a function of the inputs, so the ladder is fully unit-testable.
public struct MemoryLadder: Sendable {
    public struct Inputs: Sendable {
        public let targetMiB: UInt64
        public let floorMiB: UInt64
        public let maxMiB: UInt64
        public let availableMiB: UInt64
        public let psiSomeAvg10: Double?
        public let comfortTicks: Int
        public let justReclaimed: Bool

        public init(
            targetMiB: UInt64, floorMiB: UInt64, maxMiB: UInt64, availableMiB: UInt64,
            psiSomeAvg10: Double?, comfortTicks: Int, justReclaimed: Bool
        ) {
            self.targetMiB = targetMiB
            self.floorMiB = floorMiB
            self.maxMiB = maxMiB
            self.availableMiB = availableMiB
            self.psiSomeAvg10 = psiSomeAvg10
            self.comfortTicks = comfortTicks
            self.justReclaimed = justReclaimed
        }
    }

    public enum Action: Equatable, Sendable {
        case hold
        case grow(toMiB: UInt64)
        case shrink(toMiB: UInt64)
    }

    /// Grow when free memory drops below `max(256, target/8)` MiB.
    static let minHeadroomMiB: UInt64 = 256
    /// Grow when PSI "some" 10s average exceeds this percentage.
    static let psiPressureThreshold = 10.0
    /// Shrink only after this many consecutive comfortable polls (~30 s at 2 s).
    static let comfortTicksToShrink = 15
    /// Each shrink step frees at least this much (or target/4, whichever larger).
    static let minShrinkStepMiB: UInt64 = 512

    /// Decide the next balloon target. Grow beats shrink; both clamp to
    /// [floorMiB, maxMiB]; a collapsed range (`floor >= max`) always holds.
    public static func decide(_ input: Inputs) -> Action {
        guard input.floorMiB < input.maxMiB else { return .hold }
        assert(input.floorMiB >= 1, "floor must be positive")
        let target = min(max(input.targetMiB, input.floorMiB), input.maxMiB)
        if shouldGrow(input, target: target) {
            return growAction(target: target, maxMiB: input.maxMiB)
        }
        if shouldShrink(input, target: target) {
            return shrinkAction(target: target, floorMiB: input.floorMiB)
        }
        return .hold
    }

    private static func shouldGrow(_ input: Inputs, target: UInt64) -> Bool {
        assert(target >= 1, "clamped target must be positive")
        let starved = input.availableMiB < max(minHeadroomMiB, target / 8)
        let pressured = (input.psiSomeAvg10 ?? 0) > psiPressureThreshold
        return starved || pressured
    }

    private static func growAction(target: UInt64, maxMiB: UInt64) -> Action {
        assert(target <= maxMiB, "target must be within max before grow")
        guard target < maxMiB else { return .hold }
        let doubled = target > maxMiB / 2 ? maxMiB : target &* 2
        return .grow(toMiB: min(maxMiB, doubled))
    }

    private static func shouldShrink(_ input: Inputs, target: UInt64) -> Bool {
        assert(target >= 1, "clamped target must be positive")
        let comfortable = input.availableMiB > target / 2
        let sustained = input.comfortTicks >= comfortTicksToShrink || input.justReclaimed
        return comfortable && sustained
    }

    private static func shrinkAction(target: UInt64, floorMiB: UInt64) -> Action {
        assert(target >= floorMiB, "target must be within floor before shrink")
        guard target > floorMiB else { return .hold }
        let step = max(minShrinkStepMiB, target / 4)
        let next = step >= target ? floorMiB : max(floorMiB, target - step)
        return .shrink(toMiB: next)
    }
}
