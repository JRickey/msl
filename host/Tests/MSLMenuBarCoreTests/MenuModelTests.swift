import MSLCore
import XCTest

@testable import MSLMenuBarCore

final class MenuModelTests: XCTestCase {
    func testStoppedProbeYieldsStoppedModel() {
        let probe = DaemonProbe(running: false, status: nil, defaultDistro: nil)
        let model = MenuModel.make(probe: probe)
        XCTAssertEqual(model.daemon, .stopped)
        XCTAssertNil(model.vm)
        XCTAssertTrue(model.distros.isEmpty)
        XCTAssertTrue(model.startEnabled)
        XCTAssertFalse(model.shutDownEnabled)
        XCTAssertNil(model.vmTitle)
        XCTAssertEqual(model.daemonTitle, "Subsystem: not running")
    }

    func testRunningWithoutStatusIsTreatedAsStopped() {
        let probe = DaemonProbe(running: true, status: nil, defaultDistro: "ubuntu")
        let model = MenuModel.make(probe: probe)
        XCTAssertEqual(model.daemon, .stopped)
        XCTAssertTrue(model.distros.isEmpty)
    }

    func testRunningProbeMapsDistrosAndMarksDefault() {
        let status = StatusData(
            vm: "running",
            distros: [
                DistroStatus(name: "ubuntu", state: "running", sessions: 2),
                DistroStatus(name: "alpine", state: "stopped", sessions: 0),
            ],
            idleTimeoutS: 300)
        let probe = DaemonProbe(running: true, status: status, defaultDistro: "alpine")
        let model = MenuModel.make(probe: probe)
        XCTAssertEqual(model.daemon, .running)
        XCTAssertEqual(model.daemonTitle, "Subsystem: running")
        XCTAssertEqual(model.vm, "running")
        XCTAssertEqual(model.vmTitle, "VM: running")
        XCTAssertFalse(model.startEnabled)
        XCTAssertTrue(model.shutDownEnabled)
        XCTAssertEqual(model.distros.count, 2)
        XCTAssertFalse(model.distros[0].isDefault)
        XCTAssertTrue(model.distros[1].isDefault)
        XCTAssertEqual(model.distros[0].sessions, 2)
    }

    func testEmptyDistrosStillRunning() {
        let status = StatusData(vm: "running", distros: [], idleTimeoutS: 0)
        let probe = DaemonProbe(running: true, status: status, defaultDistro: nil)
        let model = MenuModel.make(probe: probe)
        XCTAssertEqual(model.daemon, .running)
        XCTAssertTrue(model.distros.isEmpty)
        XCTAssertEqual(model.vmTitle, "VM: running")
    }
}
