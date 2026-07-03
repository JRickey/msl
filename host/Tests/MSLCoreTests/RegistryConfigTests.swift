import Foundation
import XCTest

@testable import MSLCore

final class RegistryValidatorTests: XCTestCase {
    func testHostnameGrammar() {
        XCTAssertTrue(Registry.isValidHostname("host1"))
        XCTAssertTrue(Registry.isValidHostname("9box"))
        XCTAssertTrue(Registry.isValidHostname("a-b-c"))
        XCTAssertTrue(Registry.isValidHostname(String(repeating: "a", count: 64)))
        XCTAssertFalse(Registry.isValidHostname(""))
        XCTAssertFalse(Registry.isValidHostname("-lead"))
        XCTAssertFalse(Registry.isValidHostname("Upper"))
        XCTAssertFalse(Registry.isValidHostname("has_underscore"))
        XCTAssertFalse(Registry.isValidHostname(String(repeating: "a", count: 65)))
    }

    func testUserGrammar() {
        XCTAssertTrue(Registry.isValidUser("jack"))
        XCTAssertTrue(Registry.isValidUser("_svc"))
        XCTAssertTrue(Registry.isValidUser("user-1"))
        XCTAssertTrue(Registry.isValidUser("a_b-c"))
        XCTAssertFalse(Registry.isValidUser(""))
        XCTAssertFalse(Registry.isValidUser("1num"))
        XCTAssertFalse(Registry.isValidUser("-lead"))
        XCTAssertFalse(Registry.isValidUser("Upper"))
        XCTAssertFalse(Registry.isValidUser(String(repeating: "a", count: 33)))
    }
}

final class RegistryConfigSettersTests: XCTestCase {
    private func populated() throws -> Registry {
        var reg = Registry()
        try reg.add(
            DistroEntry(name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu", createdAt: "t"))
        return reg
    }

    func testSetHostname() throws {
        var reg = try populated()
        try reg.setHostname(name: "ubuntu", hostname: "dev-box")
        XCTAssertEqual(reg.entry(name: "ubuntu")?.hostname, "dev-box")
    }

    func testSetHostnameRejectsInvalid() throws {
        var reg = try populated()
        XCTAssertThrowsError(try reg.setHostname(name: "ubuntu", hostname: "Bad_Host"))
    }

    func testSetDefaultUserSetsAndClears() throws {
        var reg = try populated()
        try reg.setDefaultUser(name: "ubuntu", user: "jack")
        XCTAssertEqual(reg.entry(name: "ubuntu")?.defaultUser, "jack")
        try reg.setDefaultUser(name: "ubuntu", user: nil)
        XCTAssertNil(reg.entry(name: "ubuntu")?.defaultUser)
    }

    func testSetDefaultUserRejectsInvalid() throws {
        var reg = try populated()
        XCTAssertThrowsError(try reg.setDefaultUser(name: "ubuntu", user: "1bad"))
    }

    func testSetMacShareSetsAndClears() throws {
        var reg = try populated()
        try reg.setMacShare(name: "ubuntu", share: false)
        XCTAssertEqual(reg.entry(name: "ubuntu")?.macShare, false)
        try reg.setMacShare(name: "ubuntu", share: nil)
        XCTAssertNil(reg.entry(name: "ubuntu")?.macShare)
    }

    func testSetRosettaSetsAndClears() throws {
        var reg = try populated()
        XCTAssertNil(reg.entry(name: "ubuntu")?.rosetta)
        try reg.setRosetta(name: "ubuntu", on: true)
        XCTAssertEqual(reg.entry(name: "ubuntu")?.rosetta, true)
        try reg.setRosetta(name: "ubuntu", on: false)
        XCTAssertEqual(reg.entry(name: "ubuntu")?.rosetta, false)
    }

    func testSettersRejectUnknownName() throws {
        var reg = try populated()
        XCTAssertThrowsError(try reg.setHostname(name: "ghost", hostname: "ok"))
        XCTAssertThrowsError(try reg.setDefaultUser(name: "ghost", user: "j"))
        XCTAssertThrowsError(try reg.setMacShare(name: "ghost", share: true))
        XCTAssertThrowsError(try reg.setRosetta(name: "ghost", on: true))
    }

    func testSettersPreserveRosetta() throws {
        var reg = try populated()
        try reg.setRosetta(name: "ubuntu", on: true)
        try reg.setHostname(name: "ubuntu", hostname: "dev")
        try reg.setMacShare(name: "ubuntu", share: false)
        try reg.setDefaultUser(name: "ubuntu", user: "jack")
        XCTAssertEqual(reg.entry(name: "ubuntu")?.rosetta, true)
    }

    func testSettersLeaveOtherFieldsIntact() throws {
        var reg = try populated()
        try reg.setDefaultUser(name: "ubuntu", user: "jack")
        try reg.setHostname(name: "ubuntu", hostname: "dev")
        let entry = reg.entry(name: "ubuntu")
        XCTAssertEqual(entry?.defaultUser, "jack")
        XCTAssertEqual(entry?.hostname, "dev")
        XCTAssertEqual(entry?.image, "ubuntu.img")
    }
}

final class RegistryConfigPersistenceTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-reg-\(UUID().uuidString).json")
    }

    func testNewFieldsRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var reg = Registry()
        try reg.add(
            DistroEntry(name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu", createdAt: "t"))
        try reg.setDefaultUser(name: "ubuntu", user: "jack")
        try reg.setMacShare(name: "ubuntu", share: false)
        try reg.setRosetta(name: "ubuntu", on: true)
        try reg.save(to: url)
        let loaded = try Registry.load(from: url)
        XCTAssertEqual(loaded.entry(name: "ubuntu")?.defaultUser, "jack")
        XCTAssertEqual(loaded.entry(name: "ubuntu")?.macShare, false)
        XCTAssertEqual(loaded.entry(name: "ubuntu")?.rosetta, true)
    }

    func testUnsetFieldsOmittedFromJSON() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var reg = Registry()
        try reg.add(
            DistroEntry(name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu", createdAt: "t"))
        try reg.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("defaultUser"), "unset user must be an absent key: \(text)")
        XCTAssertFalse(text.contains("macShare"), "unset share must be an absent key: \(text)")
        XCTAssertFalse(text.contains("rosetta"), "unset rosetta must be an absent key: \(text)")
    }

    func testOldRegistryWithoutNewKeysLoads() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json =
            #"{"version":1,"default":"ubuntu","distros":["#
            + #"{"name":"ubuntu","image":"ubuntu.img","hostname":"h","createdAt":"t"}]}"#
        try Data(json.utf8).write(to: url)
        let loaded = try Registry.load(from: url)
        XCTAssertNil(loaded.entry(name: "ubuntu")?.defaultUser)
        XCTAssertNil(loaded.entry(name: "ubuntu")?.macShare)
        XCTAssertNil(loaded.entry(name: "ubuntu")?.rosetta)
    }
}
