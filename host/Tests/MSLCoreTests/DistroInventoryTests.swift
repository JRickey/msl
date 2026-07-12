import Darwin
import Foundation
import XCTest

@testable import MSLCore

final class DistroInventoryTests: XCTestCase {
    func testEmptyRegistryProducesEmptySnapshot() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let snapshot = try DistroInventoryService.snapshot(home: fixture.home)

        XCTAssertEqual(snapshot, DistroInventorySnapshot(items: [], defaultDistro: nil))
    }

    func testPreservesRegistryOrderAndDefault() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        var registry = Registry()
        try registry.add(Self.entry("ubuntu"))
        try registry.add(Self.entry("debian"))
        try registry.setDefault(name: "debian")
        try registry.save(to: fixture.home.registryURL)

        let snapshot = try DistroInventoryService.snapshot(home: fixture.home)

        XCTAssertEqual(snapshot.items.map { $0.entry.name }, ["ubuntu", "debian"])
        XCTAssertEqual(snapshot.items.map(\.isDefault), [false, true])
        XCTAssertEqual(snapshot.defaultDistro, "debian")
    }

    func testRegularImageMetricsMatchStat() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let image = try fixture.install(Self.entry("ubuntu"))
        try Data(repeating: 0x5a, count: 16 * 1024).write(to: image)

        let item = try XCTUnwrap(
            DistroInventoryService.snapshot(home: fixture.home).items.first)
        let expected = try Self.metrics(at: image)

        XCTAssertTrue(item.storage.imagePresent)
        XCTAssertEqual(item.storage.allocatedBytes, expected.allocated)
        XCTAssertEqual(item.storage.capacityBytes, expected.capacity)
    }

    func testSparseImageMetricsMatchStat() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let image = try fixture.install(Self.entry("ubuntu"))
        guard FileManager.default.createFile(atPath: image.path, contents: Data([0x5a])) else {
            XCTFail("could not create sparse image")
            return
        }
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()

        let item = try XCTUnwrap(
            DistroInventoryService.snapshot(home: fixture.home).items.first)
        let expected = try Self.metrics(at: image)

        XCTAssertTrue(item.storage.imagePresent)
        XCTAssertEqual(item.storage.allocatedBytes, expected.allocated)
        XCTAssertEqual(item.storage.capacityBytes, expected.capacity)
    }

    func testMissingImageIsInventoryState() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try fixture.install(Self.entry("ubuntu"))

        let item = try XCTUnwrap(
            DistroInventoryService.snapshot(home: fixture.home).items.first)

        XCTAssertEqual(
            item.storage,
            DistroStorageMetrics(imagePresent: false, allocatedBytes: 0, capacityBytes: 0))
    }

    func testNonDirectoryImagePathThrowsTypedIO() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try fixture.install(Self.entry("ubuntu"))
        try FileManager.default.removeItem(at: fixture.home.distrosDirectory)
        try Data("not a directory".utf8).write(to: fixture.home.distrosDirectory)

        XCTAssertThrowsError(try DistroInventoryService.snapshot(home: fixture.home)) { thrown in
            guard let error = thrown as? MSLError, case .io(let message) = error else {
                XCTFail("expected typed I/O error, got \(thrown)")
                return
            }
            XCTAssertTrue(message.contains("errno=\(ENOTDIR)"), message)
        }
    }

    func testIECFormattingBoundaries() {
        XCTAssertEqual(IECByteFormatter.string(from: 0), "0 B")
        XCTAssertEqual(IECByteFormatter.string(from: 1023), "1023 B")
        XCTAssertEqual(IECByteFormatter.string(from: 1024), "1.0 KiB")
        XCTAssertEqual(IECByteFormatter.string(from: 1536), "1.5 KiB")
        XCTAssertEqual(IECByteFormatter.string(from: 1024 * 1024), "1.0 MiB")
        XCTAssertEqual(IECByteFormatter.string(from: 1024 * 1024 * 1024), "1.0 GiB")
    }

    private static func entry(_ name: String) -> DistroEntry {
        XCTAssertTrue(Registry.isValidName(name))
        XCTAssertFalse(name.isEmpty)
        return DistroEntry(name: name, image: "\(name).img", hostname: name, createdAt: "now")
    }

    private static func metrics(at url: URL) throws -> (allocated: UInt64, capacity: UInt64) {
        XCTAssertTrue(url.isFileURL)
        XCTAssertFalse(url.path.isEmpty)
        var info = stat()
        let result = stat(url.path, &info)
        XCTAssertEqual(result, 0)
        guard result == 0 else { throw MSLError.io("test stat failed: errno=\(errno)") }
        return (UInt64(info.st_blocks) * 512, UInt64(info.st_size))
    }
}

private struct Fixture {
    let root: URL
    let home: MSLHome

    static func make() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-inventory-\(UUID().uuidString)")
        let home = MSLHome(root: root.appendingPathComponent("home"))
        try home.ensureDirectories()
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.root.path))
        XCTAssertTrue(home.root.isFileURL)
        return Fixture(root: root, home: home)
    }

    func install(_ entry: DistroEntry) throws -> URL {
        XCTAssertTrue(Registry.isValidName(entry.name))
        XCTAssertEqual(entry.image, "\(entry.name).img")
        var registry = try Registry.load(from: home.registryURL)
        try registry.add(entry)
        try registry.save(to: home.registryURL)
        return home.imageURL(name: entry.name)
    }

    func remove() {
        XCTAssertTrue(root.isFileURL)
        XCTAssertFalse(root.path.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }
}
