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

    func testSetGpuSetsAndClears() throws {
        var reg = try populated()
        XCTAssertNil(reg.entry(name: "ubuntu")?.gpu)
        try reg.setGpu(name: "ubuntu", on: true)
        XCTAssertEqual(reg.entry(name: "ubuntu")?.gpu, true)
        try reg.setGpu(name: "ubuntu", on: false)
        XCTAssertEqual(reg.entry(name: "ubuntu")?.gpu, false)
    }

    func testSettersRejectUnknownName() throws {
        var reg = try populated()
        XCTAssertThrowsError(try reg.setHostname(name: "ghost", hostname: "ok"))
        XCTAssertThrowsError(try reg.setDefaultUser(name: "ghost", user: "j"))
        XCTAssertThrowsError(try reg.setMacShare(name: "ghost", share: true))
        XCTAssertThrowsError(try reg.setRosetta(name: "ghost", on: true))
        XCTAssertThrowsError(try reg.setGpu(name: "ghost", on: true))
    }

    func testSettersPreserveGpu() throws {
        var reg = try populated()
        try reg.setGpu(name: "ubuntu", on: true)
        try reg.setHostname(name: "ubuntu", hostname: "dev")
        try reg.setMacShare(name: "ubuntu", share: false)
        try reg.setDefaultUser(name: "ubuntu", user: "jack")
        XCTAssertEqual(reg.entry(name: "ubuntu")?.gpu, true)
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
        try reg.setGpu(name: "ubuntu", on: false)
        try reg.save(to: url)
        let loaded = try Registry.load(from: url)
        XCTAssertEqual(loaded.entry(name: "ubuntu")?.defaultUser, "jack")
        XCTAssertEqual(loaded.entry(name: "ubuntu")?.macShare, false)
        XCTAssertEqual(loaded.entry(name: "ubuntu")?.rosetta, true)
        XCTAssertEqual(loaded.entry(name: "ubuntu")?.gpu, false)
    }

    func testCatalogSelectorRoundTripAndSetterPreservation() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var reg = Registry()
        try reg.add(
            DistroEntry(
                name: "work", image: "work.img", hostname: "work", createdAt: "t",
                catalogSelector: "ubuntu@24.04"))
        try reg.setHostname(name: "work", hostname: "dev")
        try reg.save(to: url)
        let loaded = try Registry.load(from: url)
        XCTAssertEqual(loaded.entry(name: "work")?.catalogSelector, "ubuntu@24.04")
        XCTAssertEqual(loaded.entry(name: "work")?.hostname, "dev")
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
        XCTAssertFalse(text.contains("\"gpu\""), "unset gpu must be an absent key: \(text)")
        XCTAssertFalse(
            text.contains("catalogSelector"), "unset catalog selector must be absent: \(text)")
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
        XCTAssertNil(loaded.entry(name: "ubuntu")?.gpu)
        XCTAssertNil(loaded.entry(name: "ubuntu")?.catalogSelector)
    }
}

/// The inert GPU flag's cross-validation (milestone G1.5). GPU is not
/// constructible until the krun backend ships, and it can never coexist with
/// Rosetta, so `msl config` rejects both cases before persisting.
final class GpuRosettaValidationTests: XCTestCase {
    func testGpuOffAllowsEitherRosettaState() {
        XCTAssertNoThrow(
            try Registry.validateGpuRosetta(gpuOn: false, rosettaOn: false, enablingGpu: false))
        XCTAssertNoThrow(
            try Registry.validateGpuRosetta(gpuOn: false, rosettaOn: true, enablingGpu: false))
    }

    func testEnablingGpuRejectsWithKrunMessage() {
        XCTAssertThrowsError(
            try Registry.validateGpuRosetta(gpuOn: true, rosettaOn: false, enablingGpu: true)
        ) { error in
            guard case MSLError.configuration(let message) = error else {
                return XCTFail("expected configuration error, got \(error)")
            }
            XCTAssertTrue(message.contains("krun backend"), message)
        }
    }

    /// A distro that already stores gpu=true (unreachable via the CLI today, but
    /// possible through a future import) must not have unrelated config changes
    /// rejected with the availability error — only *enabling* GPU is gated.
    func testStoredGpuWithoutEnablingPasses() {
        XCTAssertNoThrow(
            try Registry.validateGpuRosetta(gpuOn: true, rosettaOn: false, enablingGpu: false))
    }

    func testGpuWithRosettaRejectsAsMutuallyExclusive() {
        // Mutual exclusion binds on the folded state regardless of which flag
        // this invocation set, so it fires with and without enablingGpu.
        for enabling in [true, false] {  // bounded: two cases
            XCTAssertThrowsError(
                try Registry.validateGpuRosetta(gpuOn: true, rosettaOn: true, enablingGpu: enabling)
            ) { error in
                guard case MSLError.configuration(let message) = error else {
                    return XCTFail("expected configuration error, got \(error)")
                }
                XCTAssertTrue(message.contains("mutually exclusive"), message)
            }
        }
    }
}
