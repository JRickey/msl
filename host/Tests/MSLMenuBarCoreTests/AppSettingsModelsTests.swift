import MSLCore
import XCTest

@testable import MSLMenuBarCore

final class AppSettingsModelsTests: XCTestCase {
    func testDistroDraftValidation() {
        var draft = DistroSettingsDraft(distro: distro(name: "ubuntu"), defaultDistro: nil)
        draft.hostname = "Bad Host"
        XCTAssertNotNil(draft.validationError)
        draft.hostname = "ubuntu"
        draft.defaultUser = "Bad User"
        XCTAssertNotNil(draft.validationError)
        draft.defaultUser = "developer"
        XCTAssertNil(draft.validationError)
    }

    func testDefaultUserOnlyChangeDoesNotRequireRestart() throws {
        let distro = try XCTUnwrap(distro(name: "ubuntu"))
        var draft = DistroSettingsDraft(distro: distro, defaultDistro: "ubuntu")
        draft.defaultUser = "developer"
        let changes = draft.changes(from: distro, defaultDistro: "ubuntu")
        XCTAssertTrue(changes.defaultUser)
        XCTAssertFalse(changes.requiresDistroRestart)
        XCTAssertFalse(changes.requiresSubsystemRestart)
        XCTAssertFalse(changes.isEmpty)
    }

    func testBootSensitiveChangesRequireRestart() throws {
        let distro = try XCTUnwrap(distro(name: "ubuntu"))
        var draft = DistroSettingsDraft(distro: distro, defaultDistro: nil)
        draft.hostname = "workbench"
        draft.macShare = .off
        draft.rosetta = true
        let changes = draft.changes(from: distro, defaultDistro: nil)
        XCTAssertTrue(changes.hostname)
        XCTAssertTrue(changes.macShare)
        XCTAssertTrue(changes.rosetta)
        XCTAssertTrue(changes.requiresDistroRestart)
        XCTAssertTrue(changes.requiresSubsystemRestart)
    }

    func testDraftInitializationDoesNotLeakAcrossSelection() throws {
        var first = DistroSettingsDraft(distro: distro(name: "ubuntu"), defaultDistro: "ubuntu")
        first.hostname = "edited"
        let second = DistroSettingsDraft(distro: distro(name: "debian"), defaultDistro: "ubuntu")
        XCTAssertEqual(second.name, "debian")
        XCTAssertEqual(second.hostname, "debian")
        XCTAssertNotEqual(second.hostname, first.hostname)
        XCTAssertFalse(second.isDefault)
    }

    func testAutomaticAndExplicitHostDraftRoundTrips() throws {
        let automatic = HostSettingsDraft(settings: MSLHostSettings(), facts: facts())
        XCTAssertNil(try automatic.settings().cpuCount)
        XCTAssertNil(try automatic.settings().memoryMiB)
        var explicit = automatic
        explicit.automaticCPU = false
        explicit.cpuCount = 4
        explicit.automaticMemory = false
        explicit.memoryMiB = 4096
        XCTAssertEqual(try explicit.settings().cpuCount, 4)
        XCTAssertEqual(try explicit.settings().memoryMiB, 4096)
    }

    func testHostDraftValidationRejectsOutOfRangeValues() {
        var draft = HostSettingsDraft(settings: MSLHostSettings(), facts: facts())
        draft.automaticCPU = false
        draft.cpuCount = 0
        XCTAssertNotNil(draft.validationError)
        XCTAssertThrowsError(try draft.settings())
        draft.cpuCount = 2
        draft.idleTimeoutS = 86_401
        XCTAssertNotNil(draft.validationError)
    }

    func testOverviewProjectsStoppedAndRunningTruth() {
        let inventory = AppInventory(defaultDistro: "ubuntu", distros: [item(name: "ubuntu")])
        let stopped = AppOverviewSnapshot(snapshot: AppSnapshot(inventory: inventory, status: nil))
        XCTAssertFalse(stopped.daemonRunning)
        XCTAssertEqual(stopped.installedDistros, 1)
        XCTAssertEqual(stopped.runningDistros, 0)
        let status = StatusData(
            vm: "running", distros: [DistroStatus(name: "ubuntu", state: "running", sessions: 2)],
            idleTimeoutS: 60,
            memory: MemoryStatus(targetMiB: 2048, maxMiB: 8192, availableMiB: 1024),
            forwardedPorts: [3000])
        let running = AppOverviewSnapshot(
            snapshot: AppSnapshot(inventory: inventory, status: status))
        XCTAssertTrue(running.daemonRunning)
        XCTAssertEqual(running.runningDistros, 1)
        XCTAssertEqual(running.liveSessions, 2)
        XCTAssertEqual(running.memory?.targetMiB, 2048)
    }

    func testPendingRestartClearsOnlyExplicitly() {
        var pending = PendingRestarts()
        pending.mark(.distro("ubuntu"))
        pending.mark(.subsystem)
        XCTAssertTrue(pending.contains(.distro("ubuntu")))
        XCTAssertTrue(pending.contains(.subsystem))
        pending.clear(.distro("ubuntu"))
        XCTAssertFalse(pending.contains(.distro("ubuntu")))
        XCTAssertTrue(pending.contains(.subsystem))
    }

    func testSavePendingStateDistinguishesStoppedAndRunningScopes() throws {
        let distro = try XCTUnwrap(distro(name: "ubuntu"))
        var draft = DistroSettingsDraft(distro: distro, defaultDistro: nil)
        draft.hostname = "workbench"
        let changes = draft.changes(from: distro, defaultDistro: nil)
        var pending = PendingRestarts()
        pending.recordDistroSave(
            name: "ubuntu", distroActive: false, vmActive: false, changes: changes)
        pending.recordHostSave(active: false)
        XCTAssertFalse(pending.contains(.distro("ubuntu")))
        XCTAssertFalse(pending.contains(.subsystem))
        pending.recordDistroSave(
            name: "ubuntu", distroActive: true, vmActive: true, changes: changes)
        pending.recordHostSave(active: true)
        XCTAssertTrue(pending.contains(.distro("ubuntu")))
        XCTAssertTrue(pending.contains(.subsystem))
    }

    func testRosettaRequiresOnlySubsystemRestart() throws {
        let distro = try XCTUnwrap(distro(name: "ubuntu"))
        var draft = DistroSettingsDraft(distro: distro, defaultDistro: nil)
        draft.rosetta = true
        let changes = draft.changes(from: distro, defaultDistro: nil)
        var pending = PendingRestarts()
        pending.recordDistroSave(
            name: "ubuntu", distroActive: true, vmActive: true, changes: changes)
        XCTAssertFalse(pending.contains(.distro("ubuntu")))
        XCTAssertTrue(pending.contains(.subsystem))
    }

    func testDistroTransactionPreservesUntouchedConcurrentField() throws {
        let distro = try XCTUnwrap(distro(name: "ubuntu"))
        var draft = DistroSettingsDraft(distro: distro, defaultDistro: nil)
        draft.hostname = "workbench"
        let changes = draft.changes(from: distro, defaultDistro: nil)
        var registry = Registry(distros: [entry(name: "ubuntu")])
        try registry.setDefaultUser(name: "ubuntu", user: "concurrent")
        try changes.apply(draft: draft, to: &registry)
        XCTAssertEqual(registry.entry(name: "ubuntu")?.hostname, "workbench")
        XCTAssertEqual(registry.entry(name: "ubuntu")?.defaultUser, "concurrent")
    }

    func testHostTransactionPreservesUntouchedConcurrentField() throws {
        let baseline = MSLHostSettings()
        var draft = HostSettingsDraft(settings: baseline, facts: facts())
        draft.automaticCPU = false
        draft.cpuCount = 4
        let changes = try HostSettingsChanges(draft: draft, baseline: baseline)
        var concurrent = baseline
        concurrent.idleTimeoutS = 900
        try changes.apply(draft: draft, to: &concurrent)
        XCTAssertEqual(concurrent.cpuCount, 4)
        XCTAssertEqual(concurrent.idleTimeoutS, 900)
        XCTAssertTrue(concurrent.shareHome)
    }

    func testAmbiguousFirstRPCFailureRequestsPreservingRefresh() {
        let outcome = LifecycleOutcome.failed(message: "down failed")
        XCTAssertTrue(outcome.needsRefresh)
        XCTAssertEqual(outcome.pendingRefreshPolicy, .preserve)
    }

    func testSuccessfulDistroStopClearsOnlyThatDistroPendingScope() {
        var pending = PendingRestarts()
        pending.mark(.distro("ubuntu"))
        pending.mark(.distro("debian"))
        pending.mark(.subsystem)
        pending.recordLifecycle(.succeeded, effect: .distroStop("ubuntu"))
        XCTAssertFalse(pending.contains(.distro("ubuntu")))
        XCTAssertTrue(pending.contains(.distro("debian")))
        XCTAssertTrue(pending.contains(.subsystem))
    }

    func testSuccessfulSubsystemShutdownClearsAllPendingScopes() {
        var pending = PendingRestarts()
        pending.mark(.distro("ubuntu"))
        pending.mark(.subsystem)
        pending.recordLifecycle(.succeeded, effect: .subsystemStop)
        XCTAssertFalse(pending.contains(.distro("ubuntu")))
        XCTAssertFalse(pending.contains(.subsystem))
    }

    func testOrdinaryRefreshClearsAuthoritativelyStoppedDistroScope() {
        var pending = PendingRestarts()
        pending.mark(.distro("ubuntu"))
        pending.mark(.distro("debian"))
        pending.mark(.subsystem)
        let inventory = AppInventory(
            defaultDistro: "ubuntu", distros: [item(name: "ubuntu"), item(name: "debian")])
        let status = StatusData(
            vm: "running",
            distros: [
                DistroStatus(name: "ubuntu", state: "stopped", sessions: 0),
                DistroStatus(name: "debian", state: "running", sessions: 1),
            ], idleTimeoutS: 60, memory: nil, forwardedPorts: [])
        pending.reconcile(
            snapshot: AppSnapshot(inventory: inventory, status: status),
            policy: .reconcileStopped)
        XCTAssertFalse(pending.contains(.distro("ubuntu")))
        XCTAssertTrue(pending.contains(.distro("debian")))
        XCTAssertTrue(pending.contains(.subsystem))
    }

    func testFailedRestartPreservesPendingAcrossStoppedRefresh() {
        var pending = PendingRestarts()
        pending.mark(.distro("ubuntu"))
        let outcome = LifecycleOutcome.failed(message: "down failed")
        pending.recordLifecycle(outcome, effect: .distroRestart("ubuntu"))
        let inventory = AppInventory(defaultDistro: "ubuntu", distros: [item(name: "ubuntu")])
        let stopped = AppSnapshot(inventory: inventory, status: nil)
        pending.reconcile(snapshot: stopped, policy: outcome.pendingRefreshPolicy)
        XCTAssertTrue(outcome.needsRefresh)
        XCTAssertTrue(pending.contains(.distro("ubuntu")))
        XCTAssertEqual(outcome.pendingRefreshPolicy, .preserve)
    }

    private func facts() -> SharedVMHardwareFacts {
        SharedVMHardwareFacts(
            activeCPUCount: 8, performanceCoreCount: 4, physicalMemoryMiB: 16_384)
    }

    private func distro(name: String) -> AppDistroSnapshot? {
        AppSnapshot(
            inventory: AppInventory(defaultDistro: nil, distros: [item(name: name)]), status: nil
        ).distros.first
    }

    private func item(name: String) -> AppInventoryItem {
        AppInventoryItem(
            name: name, hostname: name, defaultUser: nil, macShare: nil, rosetta: false,
            createdAt: "2026-07-01T00:00:00Z", catalogSelector: nil,
            allocatedBytes: 1024, capacityBytes: 8192, finderPath: nil)
    }

    private func entry(name: String) -> DistroEntry {
        DistroEntry(
            name: name, image: "\(name).img", hostname: name,
            createdAt: "2026-07-01T00:00:00Z")
    }
}
