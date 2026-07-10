import Foundation
import XCTest

@testable import MSLCore

final class SharedVMSizingTests: XCTestCase {
    func testTenCPUHostUsesEightPerformanceCoresAndFourGiB() {
        let sizing = resolve(activeCPUs: 10, performanceCores: 8, physicalMemoryMiB: 16_384)

        XCTAssertEqual(sizing.cpuCount, 8)
        XCTAssertEqual(sizing.memoryMiB, 4096)
    }

    func testEightCPUHostUsesFourPerformanceCoresAndTwoGiB() {
        let sizing = resolve(activeCPUs: 8, performanceCores: 4, physicalMemoryMiB: 8192)

        XCTAssertEqual(sizing.cpuCount, 4)
        XCTAssertEqual(sizing.memoryMiB, 2048)
    }

    func testMissingPerformanceCoreDataFallsBackToActiveCPUs() {
        let sizing = resolve(activeCPUs: 12, performanceCores: nil, physicalMemoryMiB: 32_768)

        XCTAssertEqual(sizing.cpuCount, 8)
        XCTAssertEqual(sizing.memoryMiB, 8192)
    }

    func testTinyMalformedFactsClampSafely() {
        let zeroSizing = resolve(activeCPUs: 0, performanceCores: 0, physicalMemoryMiB: 0)
        let reservedSizing = resolve(activeCPUs: -4, performanceCores: 12, physicalMemoryMiB: 5120)

        XCTAssertEqual(zeroSizing, SharedVMSizing(cpuCount: 1, memoryMiB: 2048))
        XCTAssertEqual(reservedSizing, SharedVMSizing(cpuCount: 1, memoryMiB: 1024))
    }

    func testDaemonConfigPreservesExplicitSizing() {
        let config = DaemonConfig(
            home: MSLHome(root: URL(fileURLWithPath: "/tmp/msl-sizing-test")),
            kernelPath: "kernel", initramfsPath: "initramfs", cpus: 3, memoryMiB: 3072,
            shareHomePath: nil, sizing: SharedVMSizing(cpuCount: 7, memoryMiB: 7168))

        XCTAssertEqual(config.cpus, 3)
        XCTAssertEqual(config.memoryMiB, 3072)
    }

    func testDaemonConfigUsesOneSizingForMissingValues() {
        let sizing = SharedVMSizing(cpuCount: 6, memoryMiB: 6144)
        let config = DaemonConfig(
            home: MSLHome(root: URL(fileURLWithPath: "/tmp/msl-sizing-default-test")),
            kernelPath: "kernel", initramfsPath: "initramfs", shareHomePath: nil, sizing: sizing)

        XCTAssertEqual(config.cpus, sizing.cpuCount)
        XCTAssertEqual(config.memoryMiB, sizing.memoryMiB)
    }

    private func resolve(
        activeCPUs: Int, performanceCores: Int?, physicalMemoryMiB: UInt64
    ) -> SharedVMSizing {
        let facts = SharedVMHardwareFacts(
            activeCPUCount: activeCPUs, performanceCoreCount: performanceCores,
            physicalMemoryMiB: physicalMemoryMiB)
        return SharedVMSizing.resolve(for: facts)
    }
}
