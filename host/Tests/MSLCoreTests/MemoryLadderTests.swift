import XCTest

@testable import MSLCore

final class MemoryLadderTests: XCTestCase {
    private struct Case {
        let name: String
        let inputs: MemoryLadder.Inputs
        let expected: MemoryLadder.Action
    }

    private func inputs(
        target: UInt64, floor: UInt64 = 1024, max: UInt64 = 4096, available: UInt64,
        psi: Double? = 0, ticks: Int = 0, reclaimed: Bool = false
    ) -> MemoryLadder.Inputs {
        return MemoryLadder.Inputs(
            targetMiB: target, floorMiB: floor, maxMiB: max, availableMiB: available,
            psiSomeAvg10: psi, comfortTicks: ticks, justReclaimed: reclaimed)
    }

    func testDecisionTable() {
        let cases: [Case] = [
            Case(
                name: "grow on low available",
                inputs: inputs(target: 1024, available: 100),
                expected: .grow(toMiB: 2048)),
            Case(
                name: "grow on PSI pressure",
                inputs: inputs(target: 2048, max: 8192, available: 6000, psi: 25),
                expected: .grow(toMiB: 4096)),
            Case(
                name: "no grow past max",
                inputs: inputs(target: 4096, available: 10, psi: 50),
                expected: .hold),
            Case(
                name: "grow clamps to max",
                inputs: inputs(target: 3000, available: 10),
                expected: .grow(toMiB: 4096)),
            Case(
                name: "no shrink before sustained comfort",
                inputs: inputs(target: 2048, available: 3000, ticks: 14),
                expected: .hold),
            Case(
                name: "shrink after sustained comfort",
                inputs: inputs(target: 2048, available: 3000, ticks: 15),
                expected: .shrink(toMiB: 1536)),
            Case(
                name: "immediate shrink after reclaim",
                inputs: inputs(target: 2048, available: 3000, ticks: 0, reclaimed: true),
                expected: .shrink(toMiB: 1536)),
            Case(
                name: "shrink clamps to floor",
                inputs: inputs(target: 1200, available: 3000, ticks: 15),
                expected: .shrink(toMiB: 1024)),
            Case(
                name: "hold band: neither starved nor comfortable",
                inputs: inputs(target: 2048, available: 900, ticks: 99),
                expected: .hold),
            Case(
                name: "shrink at floor holds",
                inputs: inputs(target: 1024, available: 3000, ticks: 20),
                expected: .hold),
            Case(
                name: "collapsed range always holds",
                inputs: inputs(target: 2048, floor: 4096, max: 4096, available: 10, psi: 50),
                expected: .hold),
            Case(
                name: "nil PSI tolerated as zero",
                inputs: inputs(target: 2048, available: 1500, psi: nil, ticks: 0),
                expected: .hold),
            Case(
                name: "nil PSI still grows when starved",
                inputs: inputs(target: 1024, available: 50, psi: nil),
                expected: .grow(toMiB: 2048)),
        ]
        for testCase in cases {  // bounded: fixed decision table
            XCTAssertEqual(
                MemoryLadder.decide(testCase.inputs), testCase.expected, testCase.name)
        }
    }
}
