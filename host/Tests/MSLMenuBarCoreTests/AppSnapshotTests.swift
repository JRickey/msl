import MSLCore
import XCTest

@testable import MSLMenuBarCore

final class AppSnapshotTests: XCTestCase {
    func testStoppedDaemonPreservesInventory() {
        let snapshot = AppSnapshot(inventory: inventory(), status: nil)
        XCTAssertFalse(snapshot.daemonRunning)
        XCTAssertEqual(snapshot.vmState, "stopped")
        XCTAssertEqual(snapshot.distros.map(\.name), ["ubuntu", "debian"])
        XCTAssertEqual(snapshot.distros.map(\.state), ["stopped", "stopped"])
        XCTAssertEqual(snapshot.distros.map(\.sessions), [0, 0])
    }

    func testRuntimeOverlaysMatchingInventory() {
        let status = StatusData(
            vm: "running",
            distros: [DistroStatus(name: "ubuntu", state: "running", sessions: 2)],
            idleTimeoutS: 60, forwardedPorts: [3000, 5432])
        let snapshot = AppSnapshot(inventory: inventory(), status: status)
        XCTAssertTrue(snapshot.daemonRunning)
        XCTAssertEqual(snapshot.distro(named: "ubuntu")?.state, "running")
        XCTAssertEqual(snapshot.distro(named: "ubuntu")?.sessions, 2)
        XCTAssertEqual(snapshot.distro(named: "debian")?.state, "stopped")
        XCTAssertEqual(snapshot.forwardedPorts, [3000, 5432])
    }

    func testDefaultSelectionAndPreservation() {
        let snapshot = AppSnapshot(inventory: inventory(), status: nil)
        XCTAssertEqual(snapshot.selectedName(preserving: nil), "debian")
        XCTAssertEqual(snapshot.selectedName(preserving: "ubuntu"), "ubuntu")
        XCTAssertEqual(snapshot.selectedName(preserving: "removed"), "debian")
    }

    func testStorageLabels() throws {
        let distro = try XCTUnwrap(AppSnapshot(inventory: inventory(), status: nil).distros.first)
        XCTAssertNotEqual(distro.storageLabel(3_100_000_000), "Not available")
        XCTAssertEqual(distro.storageLabel(nil), "Not available")
        XCTAssertTrue(distro.storageLabel(3_100_000_000).contains("GB"))
    }

    func testEmptyStateHasNoSelection() {
        let snapshot = AppSnapshot.empty
        XCTAssertTrue(snapshot.distros.isEmpty)
        XCTAssertNil(snapshot.defaultDistro)
        XCTAssertNil(snapshot.selectedName(preserving: "ubuntu"))
        XCTAssertNil(snapshot.distro(named: nil))
    }

    private func inventory() -> AppInventory {
        return AppInventory(
            defaultDistro: "debian",
            distros: [
                item(name: "ubuntu", allocated: 3_100_000_000, capacity: 8_000_000_000),
                item(name: "debian", allocated: nil, capacity: nil),
            ])
    }

    private func item(name: String, allocated: UInt64?, capacity: UInt64?) -> AppInventoryItem {
        return AppInventoryItem(
            name: name, hostname: name, defaultUser: nil, macShare: nil, rosetta: false,
            createdAt: "2026-07-01T00:00:00Z", catalogSelector: nil,
            allocatedBytes: allocated, capacityBytes: capacity, finderPath: nil)
    }
}
