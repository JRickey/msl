import Foundation
import XCTest

@testable import MSLCore

/// Rosetta plumbing that is testable without booting a VM: the BootSpec flag and
/// the static availability probe. The real VZLinuxRosettaDirectoryShare is only
/// instantiated at boot, so these stay at the flag/gating layer.
final class RosettaBootSpecTests: XCTestCase {
    private func writeTempFile(_ name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-\(name)-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        return url.path
    }

    private func makeSpec(rosettaShare: Bool) throws -> BootSpec {
        let kernel = try writeTempFile("kernel")
        let initramfs = try writeTempFile("initramfs")
        defer {
            try? FileManager.default.removeItem(atPath: kernel)
            try? FileManager.default.removeItem(atPath: initramfs)
        }
        return try BootSpec(
            kernelPath: kernel, initramfsPath: initramfs, commandLine: "console=hvc0",
            cpuCount: 1, memoryMiB: 512, consoleLogPath: nil, execCommand: nil, timeout: 5,
            rosettaShare: rosettaShare)
    }

    func testRosettaShareDefaultsOff() throws {
        let spec = try makeSpec(rosettaShare: false)
        XCTAssertFalse(spec.rosettaShare)
    }

    func testRosettaShareFlagStored() throws {
        let spec = try makeSpec(rosettaShare: true)
        XCTAssertTrue(spec.rosettaShare)
    }

    func testRosettaAvailableProbeIsPure() {
        let first = VMHost.rosettaAvailable()
        let second = VMHost.rosettaAvailable()
        XCTAssertEqual(first, second, "availability probe must not mutate state")
    }
}
