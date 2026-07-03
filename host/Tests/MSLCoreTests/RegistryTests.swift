import Foundation
import XCTest

@testable import MSLCore

final class RegistryNameTests: XCTestCase {
    func testAcceptsLowercaseAndDigitsAndHyphens() {
        XCTAssertTrue(Registry.isValidName("ubuntu"))
        XCTAssertTrue(Registry.isValidName("u"))
        XCTAssertTrue(Registry.isValidName("dev-box-2"))
        XCTAssertTrue(Registry.isValidName(String(repeating: "a", count: 32)))
    }

    func testRejectsBadShapes() {
        XCTAssertFalse(Registry.isValidName(""))
        XCTAssertFalse(Registry.isValidName("Ubuntu"))
        XCTAssertFalse(Registry.isValidName("2cool"))
        XCTAssertFalse(Registry.isValidName("-lead"))
        XCTAssertFalse(Registry.isValidName("has space"))
        XCTAssertFalse(Registry.isValidName("under_score"))
        XCTAssertFalse(Registry.isValidName(String(repeating: "a", count: 33)))
    }
}

final class RegistryMutationTests: XCTestCase {
    private func entry(_ name: String) -> DistroEntry {
        DistroEntry(name: name, image: "\(name).img", hostname: name, createdAt: "t")
    }

    func testFirstAddBecomesDefault() throws {
        var reg = Registry()
        try reg.add(entry("ubuntu"))
        XCTAssertEqual(reg.defaultDistro, "ubuntu")
        try reg.add(entry("debian"))
        XCTAssertEqual(reg.defaultDistro, "ubuntu")
        XCTAssertEqual(reg.distros.count, 2)
    }

    func testDuplicateNameRejected() throws {
        var reg = Registry()
        try reg.add(entry("ubuntu"))
        XCTAssertThrowsError(try reg.add(entry("ubuntu")))
    }

    func testInvalidNameRejected() {
        var reg = Registry()
        XCTAssertThrowsError(try reg.add(entry("BAD")))
    }

    func testRemoveClearsDefaultWhenItMatched() throws {
        var reg = Registry()
        try reg.add(entry("ubuntu"))
        try reg.add(entry("debian"))
        try reg.remove(name: "ubuntu")
        XCTAssertNil(reg.defaultDistro)
        XCTAssertEqual(reg.distros.map { $0.name }, ["debian"])
    }

    func testRemoveKeepsUnrelatedDefault() throws {
        var reg = Registry()
        try reg.add(entry("ubuntu"))
        try reg.add(entry("debian"))
        try reg.remove(name: "debian")
        XCTAssertEqual(reg.defaultDistro, "ubuntu")
    }

    func testRemoveMissingThrows() {
        var reg = Registry()
        XCTAssertThrowsError(try reg.remove(name: "ghost"))
    }

    func testSetDefaultRequiresExisting() throws {
        var reg = Registry()
        try reg.add(entry("ubuntu"))
        try reg.setDefault(name: "ubuntu")
        XCTAssertEqual(reg.defaultDistro, "ubuntu")
        XCTAssertThrowsError(try reg.setDefault(name: "ghost"))
    }
}

final class RegistryDefaultResolutionTests: XCTestCase {
    private func populated() throws -> Registry {
        var reg = Registry()
        try reg.add(
            DistroEntry(name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu", createdAt: "t"))
        try reg.add(
            DistroEntry(name: "debian", image: "debian.img", hostname: "debian", createdAt: "t"))
        return reg
    }

    func testFlagWinsOverRegistryDefault() throws {
        let reg = try populated()
        let entry = try reg.resolveDefault(requested: "debian")
        XCTAssertEqual(entry.name, "debian")
    }

    func testRegistryDefaultUsedWhenNoFlag() throws {
        let reg = try populated()
        let entry = try reg.resolveDefault(requested: nil)
        XCTAssertEqual(entry.name, "ubuntu")
    }

    func testErrorWhenNoFlagAndNoDefault() {
        let reg = Registry()
        XCTAssertThrowsError(try reg.resolveDefault(requested: nil))
    }

    func testErrorOnUnknownRequestedName() throws {
        let reg = try populated()
        XCTAssertThrowsError(try reg.resolveDefault(requested: "ghost"))
    }
}

final class RegistryPersistenceTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-reg-\(UUID().uuidString).json")
    }

    func testRoundTripPreservesEverything() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var reg = Registry()
        try reg.add(
            DistroEntry(
                name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu",
                createdAt: "2026-07-02T00:00:00Z"))
        try reg.add(
            DistroEntry(
                name: "debian", image: "debian.img", hostname: "debian",
                createdAt: "2026-07-02T00:00:01Z"))
        try reg.setDefault(name: "debian")
        try reg.save(to: url)

        let loaded = try Registry.load(from: url)
        XCTAssertEqual(loaded, reg)
        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.defaultDistro, "debian")
    }

    func testMissingFileIsEmptyRegistry() throws {
        let loaded = try Registry.load(from: tempURL())
        XCTAssertEqual(loaded.distros.count, 0)
        XCTAssertNil(loaded.defaultDistro)
        XCTAssertEqual(loaded.version, 1)
    }

    func testDefaultKeySerializesAsJSONDefault() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var reg = Registry()
        try reg.add(
            DistroEntry(name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu", createdAt: "t"))
        try reg.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"default\""), "expected 'default' key, got: \(text)")
        XCTAssertFalse(text.contains("defaultDistro"))
    }

    func testSaveIsAtomicReplacingExisting() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var first = Registry()
        try first.add(
            DistroEntry(name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu", createdAt: "t"))
        try first.save(to: url)
        var second = Registry()
        try second.add(
            DistroEntry(name: "debian", image: "debian.img", hostname: "debian", createdAt: "t"))
        try second.save(to: url)
        let loaded = try Registry.load(from: url)
        XCTAssertEqual(loaded.distros.map { $0.name }, ["debian"])
    }

    func testCorruptFileThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try Registry.load(from: url))
    }
}

final class RegistryLoadValidationTests: XCTestCase {
    private func writeTemp(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-reg-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testZeroByteFileRejectedLoudly() throws {
        let url = try writeTemp("")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Registry.load(from: url)) { error in
            let message = (error as? MSLError)?.description ?? "\(error)"
            XCTAssertTrue(message.contains("empty/truncated"), "unexpected: \(message)")
        }
    }

    func testWhitespaceOnlyFileRejected() throws {
        let url = try writeTemp("   \n\t ")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Registry.load(from: url))
    }

    func testInvalidNameOnLoadRejected() throws {
        let url = try writeTemp(
            #"{"version":1,"default":null,"distros":[{"name":"BAD","image":"BAD.img","hostname":"h","createdAt":"t"}]}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Registry.load(from: url))
    }

    func testImageBasenameMismatchRejected() throws {
        let url = try writeTemp(
            #"{"version":1,"default":null,"distros":["#
                + #"{"name":"ubuntu","image":"../../etc/passwd","hostname":"h","createdAt":"t"}]}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Registry.load(from: url)) { error in
            let message = (error as? MSLError)?.description ?? "\(error)"
            XCTAssertTrue(message.contains("ubuntu.img"), "unexpected: \(message)")
        }
    }

    func testDefaultReferencingMissingEntryRejected() throws {
        let url = try writeTemp(
            #"{"version":1,"default":"ghost","distros":["#
                + #"{"name":"ubuntu","image":"ubuntu.img","hostname":"h","createdAt":"t"}]}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Registry.load(from: url))
    }

    func testDuplicateNamesOnLoadRejected() throws {
        let url = try writeTemp(
            #"{"version":1,"default":null,"distros":["#
                + #"{"name":"u","image":"u.img","hostname":"h","createdAt":"t"},"#
                + #"{"name":"u","image":"u.img","hostname":"h","createdAt":"t"}]}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try Registry.load(from: url))
    }

    func testValidFileLoads() throws {
        let url = try writeTemp(
            #"{"version":1,"default":"ubuntu","distros":["#
                + #"{"name":"ubuntu","image":"ubuntu.img","hostname":"h","createdAt":"t"}]}"#
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = try Registry.load(from: url)
        XCTAssertEqual(registry.defaultDistro, "ubuntu")
        XCTAssertEqual(registry.distros.count, 1)
    }
}
