import Foundation
import XCTest

@testable import MSLCore

final class RegistryStoreTests: XCTestCase {
    func testSimultaneousUpdatesDoNotLoseEntries() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = RegistryStore(home: home)
        let failures = FailureCollector()
        let updateCount = 32

        DispatchQueue.concurrentPerform(iterations: updateCount) { index in
            do {
                _ = try store.update { registry in
                    try registry.add(Self.entry(index: index))
                }
            } catch {
                failures.append(error)
            }
        }

        XCTAssertTrue(failures.values.isEmpty, "unexpected update errors: \(failures.values)")
        let registry = try store.load()
        XCTAssertEqual(registry.distros.count, updateCount)
        XCTAssertEqual(Set(registry.distros.map(\.name)).count, updateCount)
    }

    func testThrownMutationPreservesRegistryAndReleasesLock() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = RegistryStore(home: home)
        let original = try store.update { registry in
            try registry.add(Self.entry(index: 0))
        }
        let originalData = try Data(contentsOf: home.registryURL)

        XCTAssertThrowsError(
            try store.update { registry in
                try registry.add(Self.entry(index: 1))
                throw MutationFailure.expected
            }
        ) { error in
            XCTAssertEqual(error as? MutationFailure, .expected)
        }
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(try Data(contentsOf: home.registryURL), originalData)

        let recovered = try store.update { registry in
            try registry.add(Self.entry(index: 2))
        }
        XCTAssertEqual(recovered.distros.map(\.name).sorted(), ["distro-0", "distro-2"])
        XCTAssertEqual(try store.load(), recovered)
    }

    private func makeHome() throws -> MSLHome {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-registry-store-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let home = MSLHome(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.registryURL.path))
        return home
    }

    private static func entry(index: Int) -> DistroEntry {
        precondition((0..<100).contains(index), "test entry index must stay bounded")
        let name = "distro-\(index)"
        return DistroEntry(
            name: name,
            image: "\(name).img",
            hostname: name,
            createdAt: "2026-07-11T00:00:00Z"
        )
    }
}

private enum MutationFailure: Error, Equatable {
    case expected
}

private final class FailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    func append(_ error: Error) {
        lock.lock()
        failures.append(error)
        lock.unlock()
    }
}
