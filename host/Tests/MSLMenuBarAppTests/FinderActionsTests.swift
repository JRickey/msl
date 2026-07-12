import Foundation
import MSLCore
import MSLMenuBarCore
import XCTest

@testable import msl_menubar

@MainActor
final class FinderActionsTests: XCTestCase {
    func testMountedDistroOpensExactInventoryPath() {
        let recorder = FinderActionRecorder()
        let model = makeModel(finderPath: "/Volumes/exact ubuntu", recorder: recorder)

        model.openFinder()

        XCTAssertEqual(recorder.openedPaths, ["/Volumes/exact ubuntu"])
        XCTAssertTrue(model.finderOperations.isEmpty)
    }

    func testDeferredRefreshGloballyBlocksSecondDistroAndSettingsMutation() async {
        let gate = FinderActionGate()
        let recorder = FinderActionRecorder()
        recorder.defersRefresh = true
        let actions = AppFinderActions(
            mount: { home, name in try await gate.mount(home: home, name: name) },
            unmount: { _, _ in throw FinderTestError.unexpected })
        let model = makeModel(
            finderPath: nil, recorder: recorder, actions: actions, includesDebian: true)

        model.openFinder()
        model.openFinder()
        XCTAssertEqual(model.finderOperation(for: "ubuntu"), .mounting)
        XCTAssertTrue(model.operationInFlight)
        await waitUntil { await gate.mountCallCount == 1 }
        await gate.finishMount(path: "/tmp/msl/ubuntu")
        await waitUntil { await MainActor.run { recorder.refreshCount == 1 } }
        XCTAssertEqual(model.finderOperation(for: "ubuntu"), .mounting)
        XCTAssertTrue(recorder.openedPaths.isEmpty)
        model.distroDraft.hostname = "blocked-change"
        model.revertDistroSettings()
        XCTAssertEqual(model.distroDraft.hostname, "blocked-change")
        model.refresh()
        XCTAssertFalse(model.isRefreshing)
        model.selectedName = "debian"
        model.openFinder()
        await Task.yield()
        let mountCallCount = await gate.mountCallCount
        XCTAssertEqual(mountCallCount, 1)
        recorder.finishRefresh()
        await waitUntil { await MainActor.run { model.finderOperations.isEmpty } }

        XCTAssertEqual(recorder.openedPaths, ["/tmp/msl/ubuntu"])
        XCTAssertEqual(recorder.refreshCount, 1)
        XCTAssertFalse(model.operationInFlight)
        XCTAssertNil(model.presentedError)
        model.refresh()
        XCTAssertTrue(model.isRefreshing)
    }

    func testFinderCannotStartWhileAnotherMutationIsReserved() async {
        let gate = FinderActionGate()
        let recorder = FinderActionRecorder()
        let actions = AppFinderActions(
            mount: { home, name in try await gate.mount(home: home, name: name) },
            unmount: { _, _ in throw FinderTestError.unexpected })
        let model = makeModel(finderPath: nil, recorder: recorder, actions: actions)
        model.operationInFlight = true

        model.openFinder()
        await Task.yield()

        let mountCallCount = await gate.mountCallCount
        XCTAssertEqual(mountCallCount, 0)
        XCTAssertTrue(model.finderOperations.isEmpty)
        model.operationInFlight = false
    }

    func testUnmountSuppressesDuplicateAndRefreshesWithoutReveal() async {
        let gate = FinderActionGate()
        let recorder = FinderActionRecorder()
        let actions = AppFinderActions(
            mount: { _, _ in throw FinderTestError.unexpected },
            unmount: { home, name in try await gate.unmount(home: home, name: name) })
        let model = makeModel(
            finderPath: "/tmp/msl/ubuntu", recorder: recorder, actions: actions)

        model.unmountFromFinder()
        model.unmountFromFinder()
        XCTAssertEqual(model.finderOperation(for: "ubuntu"), .unmounting)
        await waitUntil { await gate.unmountCallCount == 1 }
        await gate.finishUnmount(path: "/tmp/msl/ubuntu")
        await waitUntil { await MainActor.run { model.finderOperations.isEmpty } }

        XCTAssertTrue(recorder.openedPaths.isEmpty)
        XCTAssertEqual(recorder.refreshCount, 1)
        XCTAssertNil(model.presentedError)
    }

    func testServiceFailureStaysPrimaryWhenRefreshAlsoFails() async {
        let recorder = FinderActionRecorder()
        recorder.refreshError = .refreshFailed
        let actions = AppFinderActions(
            mount: { _, _ in throw FinderTestError.mountFailed },
            unmount: { _, _ in throw FinderTestError.unexpected })
        let model = makeModel(finderPath: nil, recorder: recorder, actions: actions)

        model.openFinder()
        await waitUntil { await MainActor.run { model.finderOperations.isEmpty } }

        XCTAssertEqual(recorder.refreshCount, 1)
        XCTAssertTrue(model.presentedError?.contains("mountFailed") == true)
        XCTAssertTrue(model.presentedError?.contains("refreshFailed") == true)
        XCTAssertTrue(
            model.presentedError?.hasPrefix("Finder action for ubuntu failed: mountFailed") == true)
        XCTAssertTrue(recorder.openedPaths.isEmpty)
    }

    private func makeModel(
        finderPath: String?, recorder: FinderActionRecorder,
        actions: AppFinderActions = AppFinderActions(
            mount: { _, _ in throw FinderTestError.unexpected },
            unmount: { _, _ in throw FinderTestError.unexpected }),
        includesDebian: Bool = false
    ) -> MainWindowModel {
        let snapshot = Self.snapshot(finderPath: finderPath, includesDebian: includesDebian)
        return MainWindowModel(
            home: MSLHome(root: URL(fileURLWithPath: "/tmp/msl-finder-actions")),
            finderActions: actions,
            finderPathOpener: { path in recorder.open(path) },
            initialSnapshot: snapshot, initialFinderSetupState: .ready,
            finderRefresh: { try await recorder.refresh() })
    }

    private static func snapshot(finderPath: String?, includesDebian: Bool) -> AppSnapshot {
        var items = [inventoryItem(name: "ubuntu", finderPath: finderPath)]
        if includesDebian { items.append(inventoryItem(name: "debian", finderPath: nil)) }
        return AppSnapshot(
            inventory: AppInventory(defaultDistro: "ubuntu", distros: items), status: nil)
    }

    private static func inventoryItem(name: String, finderPath: String?) -> AppInventoryItem {
        return AppInventoryItem(
            name: name, hostname: name, defaultUser: nil, macShare: nil, rosetta: false,
            createdAt: "2026-01-01", catalogSelector: name, allocatedBytes: 1,
            capacityBytes: 2, finderPath: finderPath)
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        var matched = false
        for _ in 0..<100 {
            if await condition() {
                matched = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(matched)
    }
}

@MainActor
private final class FinderActionRecorder {
    private(set) var openedPaths: [String] = []
    private(set) var refreshCount = 0
    var defersRefresh = false
    var refreshError: FinderTestError?
    private var refreshContinuation: CheckedContinuation<Void, any Error>?

    func open(_ path: String) -> Bool {
        openedPaths.append(path)
        return true
    }

    func refresh() async throws {
        refreshCount += 1
        if let refreshError { throw refreshError }
        guard defersRefresh else { return }
        try await withCheckedThrowingContinuation { refreshContinuation = $0 }
    }

    func finishRefresh() {
        precondition(defersRefresh)
        precondition(refreshContinuation != nil)
        refreshContinuation?.resume(returning: ())
        refreshContinuation = nil
    }
}

private actor FinderActionGate {
    private var mountContinuation: CheckedContinuation<MountEntry, any Error>?
    private var unmountContinuation: CheckedContinuation<MountEntry, any Error>?
    private(set) var mountCallCount = 0
    private(set) var unmountCallCount = 0

    func mount(home: MSLHome, name: String) async throws -> MountEntry {
        precondition(home.root.isFileURL)
        precondition(Registry.isValidName(name))
        mountCallCount += 1
        return try await withCheckedThrowingContinuation { mountContinuation = $0 }
    }

    func unmount(home: MSLHome, name: String) async throws -> MountEntry {
        precondition(home.root.isFileURL)
        precondition(Registry.isValidName(name))
        unmountCallCount += 1
        return try await withCheckedThrowingContinuation { unmountContinuation = $0 }
    }

    func finishMount(path: String) {
        precondition(path.hasPrefix("/"))
        precondition(mountContinuation != nil)
        mountContinuation?.resume(returning: entry(path: path))
        mountContinuation = nil
    }

    func finishUnmount(path: String) {
        precondition(path.hasPrefix("/"))
        precondition(unmountContinuation != nil)
        unmountContinuation?.resume(returning: entry(path: path))
        unmountContinuation = nil
    }

    private func entry(path: String) -> MountEntry {
        precondition(path.hasPrefix("/"))
        precondition(!path.isEmpty)
        return MountEntry(name: "ubuntu", mountpoint: path, state: "mounted")
    }
}

private enum FinderTestError: Error {
    case mountFailed
    case refreshFailed
    case unexpected
}
