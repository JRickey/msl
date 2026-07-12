import CMSLSys
import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class MSLHostSettingsTests: XCTestCase {
    func testHomeUsesConfigJSONBesideOtherState() {
        let home = MSLHome(root: URL(fileURLWithPath: "/tmp/msl-home"))

        XCTAssertEqual(home.hostSettingsURL.path, "/tmp/msl-home/config.json")
        XCTAssertEqual(home.hostSettingsURL.deletingLastPathComponent().path, home.root.path)
    }

    func testMissingFileLoadsDefaults() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }

        let settings = try fixture.store.load()

        XCTAssertEqual(settings, MSLHostSettings())
        XCTAssertNil(settings.cpuCount)
        XCTAssertNil(settings.memoryMiB)
    }

    func testRoundTripUsesOwnerOnlyFiles() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        let expected = MSLHostSettings(
            cpuCount: 6, memoryMiB: 8192, idleTimeoutS: 300, shareHome: false,
            interopEnabled: false)

        try fixture.store.save(expected)
        let loaded = try fixture.store.load()

        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(try Self.permissions(fixture.url), 0o600)
        XCTAssertEqual(try Self.permissions(fixture.url.appendingPathExtension("lock")), 0o600)
    }

    func testEmptyAndCorruptFilesAreRejected() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        try fixture.prepareDirectory()
        try Data().write(to: fixture.url)
        Self.assertConfigurationError(try fixture.store.load(), contains: "empty/truncated")
        try Data("not json".utf8).write(to: fixture.url)
        Self.assertConfigurationError(try fixture.store.load(), contains: "corrupt")
    }

    func testUnknownVersionIsRejected() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        try fixture.prepareDirectory()
        let data = try JSONEncoder().encode(MSLHostSettings(version: 2))
        try data.write(to: fixture.url)

        Self.assertConfigurationError(try fixture.store.load(), contains: "unsupported")
        Self.assertConfigurationError(
            try fixture.store.save(MSLHostSettings(version: 2)), contains: "unsupported")
    }

    func testValidationBounds() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.store.save(MSLHostSettings(cpuCount: 0)))
        XCTAssertThrowsError(try fixture.store.save(MSLHostSettings(cpuCount: 65)))
        XCTAssertThrowsError(try fixture.store.save(MSLHostSettings(memoryMiB: 1023)))
        XCTAssertThrowsError(try fixture.store.save(MSLHostSettings(memoryMiB: 65537)))
        XCTAssertThrowsError(try fixture.store.save(MSLHostSettings(idleTimeoutS: -1)))
        XCTAssertThrowsError(try fixture.store.save(MSLHostSettings(idleTimeoutS: 86401)))
    }

    func testExactValidationBoundsAreAccepted() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        let minimum = MSLHostSettings(cpuCount: 1, memoryMiB: 1024, idleTimeoutS: 0)
        let maximum = MSLHostSettings(cpuCount: 64, memoryMiB: 65536, idleTimeoutS: 86400)

        try fixture.store.save(minimum)
        XCTAssertEqual(try fixture.store.load(), minimum)
        try fixture.store.save(maximum)
        XCTAssertEqual(try fixture.store.load(), maximum)
    }

    func testOverridesWinAndNilPreservesSavedValues() throws {
        let saved = MSLHostSettings(
            cpuCount: 4, memoryMiB: 4096, idleTimeoutS: 120, shareHome: true,
            interopEnabled: true)

        let inherited = try saved.applyingOverrides(
            cpuCount: nil, memoryMiB: nil, idleTimeoutS: nil, shareHome: nil,
            interopEnabled: nil)
        let overridden = try saved.applyingOverrides(
            cpuCount: 8, memoryMiB: 16384, idleTimeoutS: 0, shareHome: false,
            interopEnabled: false)

        XCTAssertEqual(inherited, saved)
        XCTAssertEqual(overridden.cpuCount, 8)
        XCTAssertEqual(overridden.memoryMiB, 16384)
        XCTAssertEqual(overridden.idleTimeoutS, 0)
        XCTAssertFalse(overridden.shareHome)
        XCTAssertFalse(overridden.interopEnabled)
    }

    func testUpdateReloadsInsideTheMutationLock() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        try fixture.store.save(MSLHostSettings(cpuCount: 2, memoryMiB: 2048))

        let updated = try fixture.store.update { settings in
            settings.cpuCount = 6
            settings.idleTimeoutS = 600
        }

        XCTAssertEqual(updated.cpuCount, 6)
        XCTAssertEqual(updated.memoryMiB, 2048)
        XCTAssertEqual(updated.idleTimeoutS, 600)
        XCTAssertEqual(try fixture.store.load(), updated)
    }

    func testMutationErrorRemainsPrimaryAndReleasesLock() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        try fixture.store.save(MSLHostSettings())

        XCTAssertThrowsError(
            try fixture.store.update { _ in throw SettingsTestError.mutation }
        ) { thrown in
            guard case SettingsTestError.mutation = thrown else {
                XCTFail("expected original mutation error, got \(thrown)")
                return
            }
        }
        let replacement = MSLHostSettings(cpuCount: 4)
        try fixture.store.save(replacement)
        XCTAssertEqual(try fixture.store.load(), replacement)
    }

    func testConcurrentUpdatesDoNotLoseFields() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        try fixture.store.save(MSLHostSettings())
        let firstEntered = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let failures = FailureBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "msl.settings.tests", attributes: .concurrent)

        group.enter()
        queue.async {
            defer { group.leave() }
            do {
                try fixture.store.update { settings in
                    _ = firstEntered.signal()
                    releaseFirst.wait()
                    settings.cpuCount = 8
                }
            } catch { failures.append(error) }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        group.enter()
        queue.async {
            defer { group.leave() }
            do {
                _ = secondStarted.signal()
                try fixture.store.update { settings in settings.memoryMiB = 16384 }
            } catch { failures.append(error) }
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 2), .success)
        _ = releaseFirst.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 4), .success)

        XCTAssertTrue(failures.values.isEmpty, "\(failures.values)")
        let loaded = try fixture.store.load()
        XCTAssertEqual(loaded.cpuCount, 8)
        XCTAssertEqual(loaded.memoryMiB, 16384)
    }

    func testHeldLockTimesOutWithinBound() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        try fixture.prepareDirectory()
        let lockURL = fixture.url.appendingPathExtension("lock")
        let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { XCTAssertEqual(Darwin.close(fd), 0) }
        XCTAssertEqual(msl_flock(fd, LOCK_EX | LOCK_NB), 0)
        let start = Date()

        XCTAssertThrowsError(try fixture.store.save(MSLHostSettings())) { thrown in
            guard let error = thrown as? MSLError, case .timedOut = error else {
                XCTFail("expected typed timeout, got \(thrown)")
                return
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.7)
        XCTAssertLessThan(elapsed, 2.5)
    }

    func testSaveAtomicallyReplacesExistingFileAndRestoresMode() throws {
        let fixture = Fixture.make()
        defer { fixture.remove() }
        try fixture.store.save(MSLHostSettings(cpuCount: 2))
        let initialID = try Self.fileID(fixture.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fixture.url.path)

        let replacement = MSLHostSettings(cpuCount: 12, idleTimeoutS: 900)
        try fixture.store.save(replacement)

        XCTAssertEqual(try fixture.store.load(), replacement)
        XCTAssertNotEqual(try Self.fileID(fixture.url), initialID)
        XCTAssertEqual(try Self.permissions(fixture.url), 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    private static func permissions(_ url: URL) throws -> UInt16 {
        XCTAssertTrue(url.isFileURL)
        XCTAssertFalse(url.path.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return number.uint16Value
    }

    private static func fileID(_ url: URL) throws -> UInt64 {
        XCTAssertTrue(url.isFileURL)
        XCTAssertFalse(url.path.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
        return number.uint64Value
    }

    private static func assertConfigurationError<T>(
        _ expression: @autoclosure () throws -> T, contains text: String
    ) {
        XCTAssertFalse(text.isEmpty)
        XCTAssertThrowsError(try expression()) { thrown in
            guard let error = thrown as? MSLError, case .configuration(let message) = error else {
                XCTFail("expected configuration error, got \(thrown)")
                return
            }
            XCTAssertTrue(message.contains(text), message)
        }
    }
}

private enum SettingsTestError: Error {
    case mutation
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    func append(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        failures.append(String(describing: error))
    }
}

private struct Fixture {
    let root: URL
    let url: URL
    let store: MSLHostSettingsStore

    static func make() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-host-settings-\(UUID().uuidString)")
        let url = root.appendingPathComponent("config.json")
        XCTAssertTrue(root.isFileURL)
        XCTAssertTrue(url.isFileURL)
        return Fixture(root: root, url: url, store: MSLHostSettingsStore(url: url))
    }

    func prepareDirectory() throws {
        XCTAssertTrue(root.isFileURL)
        XCTAssertFalse(root.path.isEmpty)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        XCTAssertTrue(root.isFileURL)
        XCTAssertFalse(root.path.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }
}
