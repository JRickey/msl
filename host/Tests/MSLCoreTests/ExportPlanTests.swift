import Foundation
import XCTest

@testable import MSLCore

final class ExportPlanTests: XCTestCase {
    private func makeHome() throws -> MSLHome {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-home-\(UUID().uuidString)")
        let home = MSLHome(root: root)
        try home.ensureDirectories()
        return home
    }

    private func registry(with name: String, defaultUser: String? = nil) throws -> Registry {
        var registry = Registry()
        try registry.add(
            DistroEntry(
                name: name, image: "\(name).img", hostname: name,
                createdAt: "2026-01-01T00:00:00Z", defaultUser: defaultUser))
        return registry
    }

    private func writableDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testValidPlanResolvesImageAndOutput() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let dir = try writableDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("ubuntu.tar").path
        let plan = try ExportPlan.make(
            name: "ubuntu", output: out, force: false,
            registry: try registry(with: "ubuntu"), home: home)
        XCTAssertEqual(plan.name, "ubuntu")
        XCTAssertEqual(plan.imageURL.path, home.imageURL(name: "ubuntu").path)
        XCTAssertEqual(plan.outputURL.path, out)
    }

    func testDefaultOutputIsNameDotTar() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let plan = try ExportPlan.make(
            name: "ubuntu", output: nil, force: false,
            registry: try registry(with: "ubuntu"), home: home)
        XCTAssertEqual(plan.outputURL.lastPathComponent, "ubuntu.tar")
        XCTAssertEqual(plan.outputURL.pathExtension, "tar")
    }

    func testUnknownDistroRejected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        XCTAssertThrowsError(
            try ExportPlan.make(
                name: "ghost", output: nil, force: false,
                registry: try registry(with: "ubuntu"), home: home))
    }

    func testInvalidNameRejected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        XCTAssertThrowsError(
            try ExportPlan.make(
                name: "BAD", output: nil, force: false,
                registry: try registry(with: "ubuntu"), home: home))
    }

    func testNonTarOutputRejected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let dir = try writableDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("ubuntu.tar.gz").path
        XCTAssertThrowsError(
            try ExportPlan.make(
                name: "ubuntu", output: out, force: false,
                registry: try registry(with: "ubuntu"), home: home))
    }

    func testTarOutputIsNotBundle() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let plan = try ExportPlan.make(
            name: "ubuntu", output: nil, force: false,
            registry: try registry(with: "ubuntu", defaultUser: "jack"), home: home)
        XCTAssertFalse(plan.bundle)
        XCTAssertNil(plan.defaultUser)
    }

    func testMslOutputSetsBundleAndCopiesDefaultUser() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let dir = try writableDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("ubuntu.msl").path
        let plan = try ExportPlan.make(
            name: "ubuntu", output: out, force: false,
            registry: try registry(with: "ubuntu", defaultUser: "jack"), home: home)
        XCTAssertTrue(plan.bundle)
        XCTAssertEqual(plan.outputURL.pathExtension, "msl")
        XCTAssertEqual(plan.defaultUser, "jack")
    }

    func testMslOutputWithoutDefaultUser() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let dir = try writableDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("ubuntu.msl").path
        let plan = try ExportPlan.make(
            name: "ubuntu", output: out, force: false,
            registry: try registry(with: "ubuntu"), home: home)
        XCTAssertTrue(plan.bundle)
        XCTAssertNil(plan.defaultUser)
    }

    func testMissingOutputDirectoryRejected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString)/ubuntu.tar").path
        XCTAssertThrowsError(
            try ExportPlan.make(
                name: "ubuntu", output: out, force: false,
                registry: try registry(with: "ubuntu"), home: home))
    }

    func testExistingOutputRejectedWithoutForce() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let dir = try writableDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("ubuntu.tar")
        try Data("old".utf8).write(to: out)
        XCTAssertThrowsError(
            try ExportPlan.make(
                name: "ubuntu", output: out.path, force: false,
                registry: try registry(with: "ubuntu"), home: home))
    }

    func testExistingOutputAllowedWithForce() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let dir = try writableDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("ubuntu.tar")
        try Data("old".utf8).write(to: out)
        let plan = try ExportPlan.make(
            name: "ubuntu", output: out.path, force: true,
            registry: try registry(with: "ubuntu"), home: home)
        XCTAssertEqual(plan.outputURL.path, out.path)
    }

    func testExportScriptMountsReadOnlyAndTars() {
        let script = ExportDriver.exportScript(bundle: false)
        XCTAssertTrue(script.contains("mount -t ext4 -o ro /dev/vda /mnt"))
        XCTAssertTrue(script.contains("/run/msl/staging/export.tar"))
        XCTAssertTrue(script.contains("--numeric-owner"))
        XCTAssertTrue(script.contains("--exclude=./lost+found"))
        XCTAssertFalse(script.contains("mkfs"))
        XCTAssertFalse(script.contains("msl-distribution.conf"))
    }

    func testBundleExportScriptAppendsConf() {
        let script = ExportDriver.exportScript(bundle: true)
        XCTAssertTrue(script.contains("-cpf /run/msl/staging/export.tar"))
        XCTAssertTrue(script.contains("-rpf /run/msl/staging/export.tar"))
        XCTAssertTrue(script.contains("--owner=0 --group=0 --mode=0644"))
        XCTAssertTrue(script.contains("-C /run/msl/staging/meta ./etc/msl-distribution.conf"))
        // The create must drop any baked-in conf so exactly one member remains.
        XCTAssertTrue(script.contains("--exclude=./etc/msl-distribution.conf"))
        // The append must land after the create and before the unmount.
        guard let create = script.range(of: "-cpf"), let append = script.range(of: "-rpf"),
            let umount = script.range(of: "umount")
        else { return XCTFail("script missing expected steps") }
        XCTAssertTrue(create.lowerBound < append.lowerBound)
        XCTAssertTrue(append.lowerBound < umount.lowerBound)
    }

    func testTarExportScriptDoesNotExcludeConf() {
        let script = ExportDriver.exportScript(bundle: false)
        XCTAssertFalse(script.contains("--exclude=./etc/msl-distribution.conf"))
        XCTAssertTrue(script.contains("--exclude=./lost+found"))
    }

    func testBundleModeRejectsInvalidRegistryDefaultUser() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let dir = try writableDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var registry = Registry()
        try registry.add(
            DistroEntry(
                name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu",
                createdAt: "2026-01-01T00:00:00Z", defaultUser: "bad\nuser"))
        let tarOut = dir.appendingPathComponent("ubuntu.tar").path
        // A .tar export is a faithful filesystem copy; the bad value is not rendered.
        XCTAssertNoThrow(
            try ExportPlan.make(
                name: "ubuntu", output: tarOut, force: false, registry: registry, home: home))
        let mslOut = dir.appendingPathComponent("ubuntu.msl").path
        XCTAssertThrowsError(
            try ExportPlan.make(
                name: "ubuntu", output: mslOut, force: false, registry: registry, home: home)
        ) { error in
            guard case MSLError.configuration = error else {
                return XCTFail("expected configuration error, got \(error)")
            }
        }
    }
}

final class PlainTarInstallTests: XCTestCase {
    private func tempFile(suffix: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-src-\(UUID().uuidString)\(suffix)").path
        guard FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) else {
            throw MSLError.io("cannot create temp source")
        }
        return path
    }

    func testPlainTarClassifiedAsNone() throws {
        let path = try tempFile(suffix: ".tar")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plan = try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 8, existingNames: [])
        guard case .tarball(_, let comp) = plan.source else { return XCTFail("expected tarball") }
        XCTAssertEqual(comp, .none)
        XCTAssertEqual(comp.tarExtractFlag, "")
        XCTAssertEqual(comp.stagedFilename, "rootfs.tar")
    }

    func testPlainTarBuildScriptUsesEmptyFlag() {
        let script = InstallDriver.buildScript(
            tarball: TarCompression.none.stagedFilename, hostname: "d",
            tarFlag: TarCompression.none.tarExtractFlag)
        XCTAssertTrue(script.contains("-xpf /run/msl/staging/rootfs.tar"))
    }
}
