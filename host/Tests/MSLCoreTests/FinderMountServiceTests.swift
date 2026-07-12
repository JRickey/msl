import Foundation
import XCTest

@testable import MSLCore

final class FinderMountServiceTests: XCTestCase {
    func testMountUsesExactFSKitArgumentsAndCommits() throws {
        let runner = RecordingMountRunner(result: .init(status: 0, stderr: ""))
        let daemon = RecordingMountDaemon()
        let service = Self.service(runner: runner, daemon: daemon)

        let mounted = try service.mount(home: Self.home, name: "ubuntu", readOnly: true)

        let expectedArguments = [
            "-F", "-t", "mslfs", "msl://ubuntu?token", "/tmp/msl/ubuntu",
        ]
        let expectedCall = MountProcessCall(
            executable: "/sbin/mount", arguments: expectedArguments)
        XCTAssertEqual(runner.calls, [expectedCall])
        XCTAssertEqual(daemon.prepareCalls, [.init(name: "ubuntu", readOnly: true)])
        XCTAssertEqual(
            daemon.commitCalls, [.init(name: "ubuntu", mountpoint: "/tmp/msl/ubuntu")])
        XCTAssertTrue(daemon.unmountCalls.isEmpty)
        XCTAssertEqual(
            mounted, MountEntry(name: "ubuntu", mountpoint: "/tmp/msl/ubuntu", state: "mounted"))
    }

    func testMkdirFailureForcesCleanupAndPreservesPrimaryError() {
        let runner = RecordingMountRunner(result: .init(status: 0, stderr: ""))
        let daemon = RecordingMountDaemon()
        let service = FinderMountService(
            processRunner: runner, daemon: daemon,
            createDirectory: { _ in throw MountTestError.mkdir })

        Self.assertThrows(try service.mount(home: Self.home, name: nil, readOnly: false), .mkdir)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(daemon.unmountCalls, [.init(name: "ubuntu", force: true)])
        XCTAssertTrue(daemon.commitCalls.isEmpty)
    }

    func testCleanupFailureReportsPrimaryAndReconciliationErrors() {
        let runner = RecordingMountRunner(result: .init(status: 0, stderr: ""))
        let daemon = RecordingMountDaemon()
        daemon.unmountError = .io("cleanup failed")
        let service = FinderMountService(
            processRunner: runner, daemon: daemon,
            createDirectory: { _ in throw MountTestError.mkdir })

        XCTAssertThrowsError(try service.mount(home: Self.home, name: nil, readOnly: false)) {
            guard let composite = $0 as? FinderMountCleanupError else {
                XCTFail("expected FinderMountCleanupError, got \($0)")
                return
            }
            XCTAssertEqual(composite.primaryError as? MountTestError, .mkdir)
            XCTAssertTrue(String(describing: composite.cleanupError).contains("cleanup failed"))
            XCTAssertTrue(composite.localizedDescription.contains("mkdir"))
            XCTAssertTrue(composite.localizedDescription.contains("cleanup failed"))
        }
        XCTAssertEqual(daemon.unmountCalls, [.init(name: "ubuntu", force: true)])
    }

    func testMountFailureForcesCleanupAndPreservesPrimaryError() {
        let runner = RecordingMountRunner(result: .init(status: 9, stderr: "mount broke"))
        let daemon = RecordingMountDaemon()
        let service = Self.service(runner: runner, daemon: daemon)

        XCTAssertThrowsError(try service.mount(home: Self.home, name: "ubuntu", readOnly: false)) {
            XCTAssertTrue(String(describing: $0).contains("mount broke"))
        }
        XCTAssertEqual(daemon.unmountCalls, [.init(name: "ubuntu", force: true)])
        XCTAssertTrue(daemon.commitCalls.isEmpty)
    }

    func testCommitFailureForcesCleanupAndPreservesPrimaryError() {
        let runner = RecordingMountRunner(result: .init(status: 0, stderr: ""))
        let daemon = RecordingMountDaemon()
        daemon.commitError = .configuration("commit failed")
        let service = Self.service(runner: runner, daemon: daemon)

        XCTAssertThrowsError(try service.mount(home: Self.home, name: "ubuntu", readOnly: false)) {
            XCTAssertTrue(String(describing: $0).contains("commit failed"))
        }
        XCTAssertEqual(daemon.commitCalls.count, 1)
        XCTAssertEqual(daemon.unmountCalls, [.init(name: "ubuntu", force: true)])
    }

    func testUnmountSuccessUsesExactArgumentsAndClearsState() throws {
        let runner = RecordingMountRunner(result: .init(status: 0, stderr: ""))
        let daemon = RecordingMountDaemon()
        let service = Self.service(runner: runner, daemon: daemon)

        let unmounted = try service.unmount(home: Self.home, name: "ubuntu", force: false)

        XCTAssertEqual(
            runner.calls,
            [.init(executable: "/sbin/umount", arguments: ["/tmp/msl/ubuntu"])])
        XCTAssertEqual(daemon.unmountCalls, [.init(name: "ubuntu", force: false)])
        XCTAssertEqual(unmounted, daemon.mounts[0])
        XCTAssertEqual(daemon.statusCalls, 1)
    }

    func testNonforceUnmountFailurePreservesDaemonState() {
        let runner = RecordingMountRunner(result: .init(status: 7, stderr: "busy"))
        let daemon = RecordingMountDaemon()
        let service = Self.service(runner: runner, daemon: daemon)

        XCTAssertThrowsError(try service.unmount(home: Self.home, name: "ubuntu", force: false)) {
            XCTAssertTrue(String(describing: $0).contains("busy"))
        }
        XCTAssertTrue(daemon.unmountCalls.isEmpty)
    }

    func testForceUnmountFailureStillReconcilesDaemon() throws {
        let runner = RecordingMountRunner(result: .init(status: 7, stderr: "busy"))
        let daemon = RecordingMountDaemon()
        let service = Self.service(runner: runner, daemon: daemon)

        try service.unmount(home: Self.home, name: nil, force: true)

        XCTAssertEqual(
            runner.calls,
            [.init(executable: "/sbin/umount", arguments: ["-f", "/tmp/msl/ubuntu"])])
        XCTAssertEqual(daemon.unmountCalls, [.init(name: "ubuntu", force: true)])
    }

    func testUnnamedUnmountRejectsAmbiguousMountsBeforeProcess() {
        let runner = RecordingMountRunner(result: .init(status: 0, stderr: ""))
        let daemon = RecordingMountDaemon()
        daemon.mounts.append(
            MountEntry(name: "debian", mountpoint: "/tmp/msl/debian", state: "mounted"))
        let service = Self.service(runner: runner, daemon: daemon)

        XCTAssertThrowsError(try service.unmount(home: Self.home, name: nil, force: false))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(daemon.unmountCalls.isEmpty)
    }

    private static let home = MSLHome(root: URL(fileURLWithPath: "/tmp/msl-home"))

    private static func service(
        runner: RecordingMountRunner, daemon: RecordingMountDaemon
    ) -> FinderMountService {
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(daemon.unmountCalls.isEmpty)
        return FinderMountService(
            processRunner: runner, daemon: daemon, createDirectory: { _ in })
    }

    private static func assertThrows<T>(
        _ expression: @autoclosure () throws -> T, _ error: MountTestError
    ) {
        XCTAssertThrowsError(try expression()) { thrown in
            guard let thrown = thrown as? MountTestError else {
                XCTFail("expected mount test error, got \(thrown)")
                return
            }
            XCTAssertEqual(thrown, error)
        }
    }
}

private enum MountTestError: Error, Equatable {
    case mkdir
}

private struct MountProcessCall: Equatable {
    let executable: String
    let arguments: [String]
}

private final class RecordingMountRunner: FinderMountProcessRunning, @unchecked Sendable {
    private let result: FinderMountProcessResult
    private(set) var calls: [MountProcessCall] = []

    init(result: FinderMountProcessResult) {
        self.result = result
    }

    func run(executable: String, arguments: [String]) -> FinderMountProcessResult {
        calls.append(MountProcessCall(executable: executable, arguments: arguments))
        return result
    }
}

private struct PrepareCall: Equatable {
    let name: String?
    let readOnly: Bool
}

private struct CommitCall: Equatable {
    let name: String
    let mountpoint: String
}

private struct UnmountCall: Equatable {
    let name: String
    let force: Bool
}

private final class RecordingMountDaemon: FinderMountDaemon, @unchecked Sendable {
    var prepareCalls: [PrepareCall] = []
    var commitCalls: [CommitCall] = []
    var unmountCalls: [UnmountCall] = []
    var commitError: MSLError?
    var unmountError: MSLError?
    var mounts = [MountEntry(name: "ubuntu", mountpoint: "/tmp/msl/ubuntu", state: "mounted")]
    private(set) var statusCalls = 0

    func prepare(home: MSLHome, name: String?, readOnly: Bool) throws -> MountPrepareData {
        XCTAssertTrue(home.root.isFileURL)
        XCTAssertFalse(home.root.path.isEmpty)
        prepareCalls.append(PrepareCall(name: name, readOnly: readOnly))
        return MountPrepareData(
            name: "ubuntu", url: "msl://ubuntu?token", mountpoint: "/tmp/msl/ubuntu",
            mountID: "mount", nonce: "nonce")
    }

    func commit(home: MSLHome, name: String, mountpoint: String) throws {
        XCTAssertTrue(home.root.isFileURL)
        XCTAssertFalse(name.isEmpty)
        commitCalls.append(CommitCall(name: name, mountpoint: mountpoint))
        if let commitError { throw commitError }
    }

    func unmount(home: MSLHome, name: String, force: Bool) throws {
        XCTAssertTrue(home.root.isFileURL)
        XCTAssertFalse(name.isEmpty)
        unmountCalls.append(UnmountCall(name: name, force: force))
        if let unmountError { throw unmountError }
    }

    func status(home: MSLHome) throws -> MountStatusData {
        XCTAssertTrue(home.root.isFileURL)
        XCTAssertFalse(home.root.path.isEmpty)
        statusCalls += 1
        return MountStatusData(mounts: mounts)
    }
}
