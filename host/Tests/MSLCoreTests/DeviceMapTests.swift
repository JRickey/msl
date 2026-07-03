import Foundation
import XCTest

@testable import MSLCore

final class DeviceMapTests: XCTestCase {
    private func path(_ name: String) -> String { "/store/\(name).img" }

    func testNameSortedSequentialDevices() {
        let mapping = DeviceMap.compute(
            names: ["ubuntu", "alpine", "debian"], imagePath: path, isReadable: { _ in true })
        XCTAssertEqual(
            mapping.entries,
            [
                DeviceEntry(name: "alpine", dev: "/dev/vda", imagePath: path("alpine")),
                DeviceEntry(name: "debian", dev: "/dev/vdb", imagePath: path("debian")),
                DeviceEntry(name: "ubuntu", dev: "/dev/vdc", imagePath: path("ubuntu")),
            ])
        XCTAssertTrue(mapping.skipped.isEmpty)
        XCTAssertEqual(mapping.diskPaths, [path("alpine"), path("debian"), path("ubuntu")])
    }

    func testMissingImagesSkippedWithoutConsumingLetters() {
        let mapping = DeviceMap.compute(
            names: ["ubuntu", "alpine", "debian"], imagePath: path,
            isReadable: { $0 != self.path("debian") })
        XCTAssertEqual(
            mapping.entries,
            [
                DeviceEntry(name: "alpine", dev: "/dev/vda", imagePath: path("alpine")),
                DeviceEntry(name: "ubuntu", dev: "/dev/vdb", imagePath: path("ubuntu")),
            ])
        XCTAssertEqual(mapping.skipped, ["debian"])
    }

    func testEmptyRegistryProducesEmptyMapping() {
        let mapping = DeviceMap.compute(names: [], imagePath: path, isReadable: { _ in true })
        XCTAssertTrue(mapping.entries.isEmpty)
        XCTAssertTrue(mapping.skipped.isEmpty)
    }

    func testCapsAtTwentySixDevices() {
        let names = (0..<30).map { String(format: "d%02d", $0) }
        let mapping = DeviceMap.compute(names: names, imagePath: path, isReadable: { _ in true })
        XCTAssertEqual(mapping.entries.count, 26)
        XCTAssertEqual(mapping.entries.last?.dev, "/dev/vdz")
        XCTAssertEqual(mapping.skipped.count, 4)
    }
}
