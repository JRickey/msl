import Foundation
import XCTest

@testable import MSLCore

final class InstallPlanTests: XCTestCase {
    private func tempFile(suffix: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-src-\(UUID().uuidString)\(suffix)").path
        guard FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) else {
            throw MSLError.io("cannot create temp source")
        }
        return path
    }

    func testImageSourceClassified() throws {
        let path = try tempFile(suffix: ".img")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plan = try InstallPlan.make(
            name: "ubuntu", fromPath: path, sizeGiB: 8, existingNames: [])
        XCTAssertEqual(plan.name, "ubuntu")
        XCTAssertEqual(plan.hostname, "ubuntu")
        guard case .image = plan.source else { return XCTFail("expected .image") }
    }

    func testTarXzClassified() throws {
        let path = try tempFile(suffix: ".tar.xz")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plan = try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 8, existingNames: [])
        guard case .tarball(_, let comp) = plan.source else { return XCTFail("expected tarball") }
        XCTAssertEqual(comp, .xz)
        XCTAssertEqual(comp.tarExtractFlag, "J")
    }

    func testTarGzClassified() throws {
        let path = try tempFile(suffix: ".tar.gz")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plan = try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 8, existingNames: [])
        guard case .tarball(_, let comp) = plan.source else { return XCTFail("expected tarball") }
        XCTAssertEqual(comp, .gzip)
        XCTAssertEqual(comp.tarExtractFlag, "z")
    }

    func testInvalidNameRejected() throws {
        let path = try tempFile(suffix: ".img")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(
            try InstallPlan.make(name: "BAD", fromPath: path, sizeGiB: 8, existingNames: []))
    }

    func testDuplicateNameRejected() throws {
        let path = try tempFile(suffix: ".img")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(
            try InstallPlan.make(
                name: "ubuntu", fromPath: path, sizeGiB: 8, existingNames: ["ubuntu"]))
    }

    func testMissingSourceRejected() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).img").path
        XCTAssertThrowsError(
            try InstallPlan.make(name: "u", fromPath: missing, sizeGiB: 8, existingNames: []))
    }

    func testUnsupportedTypeRejected() throws {
        let path = try tempFile(suffix: ".zip")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(
            try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 8, existingNames: []))
    }

    func testSizeBoundsEnforced() throws {
        let path = try tempFile(suffix: ".tar.xz")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(
            try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 0, existingNames: []))
        XCTAssertThrowsError(
            try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 513, existingNames: []))
        XCTAssertNoThrow(
            try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 1, existingNames: []))
    }

    func testMslWithSniffedCompressionClassified() throws {
        let path = try tempFile(suffix: ".msl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plan = try InstallPlan.make(
            name: "u", fromPath: path, sizeGiB: 8, existingNames: [], bundleCompression: .gzip)
        guard case .tarball(_, let comp) = plan.source else { return XCTFail("expected tarball") }
        XCTAssertEqual(comp, .gzip)
    }

    func testMslWithoutSniffedCompressionRejected() throws {
        let path = try tempFile(suffix: ".msl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(
            try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 8, existingNames: []))
    }

    func testWslWithSniffedCompressionClassified() throws {
        let path = try tempFile(suffix: ".wsl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plan = try InstallPlan.make(
            name: "u", fromPath: path, sizeGiB: 8, existingNames: [], bundleCompression: .xz)
        guard case .tarball(_, let comp) = plan.source else { return XCTFail("expected tarball") }
        XCTAssertEqual(comp, .xz)
    }

    func testWslWithoutSniffedCompressionRejected() throws {
        let path = try tempFile(suffix: ".wsl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(
            try InstallPlan.make(name: "u", fromPath: path, sizeGiB: 8, existingNames: []))
    }

    func testDefaultUserThreadsToPlan() throws {
        let path = try tempFile(suffix: ".msl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plan = try InstallPlan.make(
            name: "u", fromPath: path, sizeGiB: 8, existingNames: [],
            bundleCompression: TarCompression.none, defaultUser: "jack")
        XCTAssertEqual(plan.defaultUser, "jack")
    }

    func testCatalogSelectorThreadsToPlan() throws {
        let path = try tempFile(suffix: ".tar.xz")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let plan = try InstallPlan.make(
            name: "work", fromPath: path, sizeGiB: 8, existingNames: [],
            catalogSelector: "ubuntu@24.04")
        XCTAssertEqual(plan.catalogSelector, "ubuntu@24.04")
    }

    func testInvalidDefaultUserRejected() throws {
        let path = try tempFile(suffix: ".msl")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(
            try InstallPlan.make(
                name: "u", fromPath: path, sizeGiB: 8, existingNames: [],
                bundleCompression: TarCompression.none, defaultUser: "Bad User"))
    }

    func testBuildScriptReferencesFixedStagedName() {
        let script = InstallDriver.buildScript(
            tarball: TarCompression.xz.stagedFilename, hostname: "mydistro",
            tarFlag: TarCompression.xz.tarExtractFlag)
        XCTAssertTrue(script.contains("mkfs.ext4"))
        XCTAssertTrue(script.contains("echo mydistro > /mnt/etc/hostname"))
        XCTAssertTrue(script.contains("-xJpf /run/msl/staging/rootfs.tar.xz"))
        XCTAssertTrue(
            script.contains("test -x /mnt/usr/lib/systemd/systemd || test -x /mnt/sbin/init"))
    }

    func testBuildScriptSeedsValidNetplanIndentation() {
        let script = InstallDriver.buildScript(
            tarball: TarCompression.none.stagedFilename, hostname: "d",
            tarFlag: TarCompression.none.tarExtractFlag)
        // `match` must sit two levels under `all` (printf-escaped \n literals);
        // a Swift line-continuation once collapsed this indent and broke DHCP.
        XCTAssertTrue(script.contains("    all:\\n      match: {name:"))
        XCTAssertFalse(script.contains("\n  match:"))
    }
}

final class InstallStagingTests: XCTestCase {
    func testStagedFilenamesAreFixedConstants() {
        XCTAssertEqual(TarCompression.xz.stagedFilename, "rootfs.tar.xz")
        XCTAssertEqual(TarCompression.gzip.stagedFilename, "rootfs.tar.gz")
    }

    func testStageIgnoresSourceBasename() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("msl-stage-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        // A hostile source basename must not survive into the staged name.
        let src = root.appendingPathComponent("evil; rm -rf.tar.gz")
        try Data("x".utf8).write(to: src)
        let stageDir = root.appendingPathComponent("staging")
        try fileManager.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let staged = try InstallDriver.stage(source: src, compression: .gzip, into: stageDir)
        XCTAssertEqual(staged.lastPathComponent, "rootfs.tar.gz")
        XCTAssertTrue(fileManager.fileExists(atPath: staged.path))
    }
}

final class InstallCleanupTests: XCTestCase {
    func testImageCleanedWhenRegistryLoadFailsAfterCopy() throws {
        let fileManager = FileManager.default
        let home = MSLHome(
            root: fileManager.temporaryDirectory
                .appendingPathComponent("msl-home-\(UUID().uuidString)"))
        try home.ensureDirectories()
        defer { try? fileManager.removeItem(at: home.root) }
        // A corrupt registry makes install throw AFTER the image is materialized.
        try Data("{ corrupt".utf8).write(to: home.registryURL)
        let src = home.root.appendingPathComponent("src.img")
        try Data("img".utf8).write(to: src)
        let plan = try InstallPlan.make(
            name: "ubuntu", fromPath: src.path, sizeGiB: 8, existingNames: [])
        let options = InstallOptions(kernelPath: "/x", builderInitramfsPath: "/y")
        XCTAssertThrowsError(try InstallDriver(home: home).install(plan: plan, options: options))
        let image = home.imageURL(name: "ubuntu").path
        XCTAssertFalse(fileManager.fileExists(atPath: image), "orphan image left behind")
        XCTAssertFalse(
            fileManager.fileExists(atPath: image + ".lock"), "orphan sidecar left behind")
    }
}
