import Foundation
import XCTest

@testable import MSLCore

final class LauncherTests: XCTestCase {
    func testCreateWritesOwnedLauncherAndManifest() throws {
        let fixture = try Fixture.make()
        let app = try fixture.store.create(name: "ubuntu", mode: .shell, replace: false)
        let record = try fixture.store.record(in: app)
        XCTAssertEqual(record.distro, "ubuntu")
        XCTAssertEqual(record.launchMode, .shell)
        XCTAssertTrue(record.isOwnedDistro)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: appScript(app).path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: appIcon(app).path))
        XCTAssertEqual(try infoPlist(app)["CFBundleIconFile"] as? String, "msl-distro")
        let rows = try fixture.store.rows(registry: Registry(distros: [fixture.entry]))
        XCTAssertEqual(
            rows, [LauncherRow(distro: "ubuntu", path: app.path, launchMode: .shell, exists: true)])
    }

    func testCreateRefusesExistingWithoutReplace() throws {
        let fixture = try Fixture.make()
        _ = try fixture.store.create(name: "ubuntu", mode: .shell, replace: false)
        XCTAssertThrowsError(try fixture.store.create(name: "ubuntu", mode: .shell, replace: false))
    }

    func testCreateRefusesNonOwnedBundle() throws {
        let fixture = try Fixture.make()
        let app = fixture.store.appURL(name: "ubuntu")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try fixture.store.create(name: "ubuntu", mode: .shell, replace: true))
    }

    func testRemoveDeletesOwnedLauncherAndManifest() throws {
        let fixture = try Fixture.make()
        let app = try fixture.store.create(name: "ubuntu", mode: .shell, replace: false)
        try fixture.store.remove(name: "ubuntu")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        let rows = try fixture.store.rows(registry: Registry(distros: [fixture.entry]))
        XCTAssertEqual(rows.first?.exists, false)
        XCTAssertNil(rows.first?.launchMode)
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(LauncherStore.shellQuote("/tmp/a'b"), "'/tmp/a'\\''b'")
    }

    func testDefaultApplicationsDirectoryHonorsEnvironment() {
        let url = LauncherStore.defaultApplicationsDirectory(
            env: ["MSL_APPLICATIONS_DIR": "/tmp/msl-apps"],
            localApplicationsDirectory: URL(fileURLWithPath: "/Applications"))
        XCTAssertEqual(url.path, "/tmp/msl-apps")
    }

    func testDefaultApplicationsDirectoryUsesLocalApplicationsDirectory() {
        let url = LauncherStore.defaultApplicationsDirectory(
            env: [:], localApplicationsDirectory: URL(fileURLWithPath: "/Applications"))
        XCTAssertEqual(url.path, "/Applications")
    }

    func testCreateRejectsFileAtLauncherDirectoryPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-launcher-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcherDir = root.appendingPathComponent("msl")
        try Data("not a directory".utf8).write(to: launcherDir)
        let fixture = try Fixture.make(root: root, apps: launcherDir)
        XCTAssertThrowsError(
            try fixture.store.create(name: "ubuntu", mode: .shell, replace: false)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("not a directory"))
        }
    }

    func testCreateBuildsCanonicalApplicationsDirectoryWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-launcher-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try Fixture.make(root: root, apps: root.appendingPathComponent("msl"))
        let app = try fixture.store.create(name: "ubuntu", mode: .shell, replace: false)
        XCTAssertEqual(app.path, root.appendingPathComponent("msl/Ubuntu.app").path)
    }

    func testCreateRemovesLegacyNestedLauncher() throws {
        let fixture = try Fixture.make()
        let legacy = fixture.apps.appendingPathComponent("msl/ubuntu.app")
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(LauncherRecord(distro: "ubuntu", launchMode: .shell))
        try data.write(to: legacy.appendingPathComponent("Contents/Resources/launcher.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        let app = try fixture.store.create(name: "ubuntu", mode: .shell, replace: false)
        XCTAssertEqual(app.lastPathComponent, "Ubuntu.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testCreateCopiesProvidedIcon() throws {
        let fixture = try Fixture.make()
        let icon = fixture.root.appendingPathComponent("provided.icns")
        try Data("icns-test".utf8).write(to: icon)
        let app = try fixture.store.create(name: "ubuntu", mode: .shell, replace: false, icon: icon)
        XCTAssertEqual(try Data(contentsOf: appIcon(app)), Data("icns-test".utf8))
    }

    func testFallbackIconIsICNSContainer() throws {
        let fixture = try Fixture.make()
        let app = try fixture.store.create(name: "ubuntu", mode: .shell, replace: false)
        let data = try Data(contentsOf: appIcon(app))
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "icns")
        XCTAssertGreaterThan(data.count, 1024)
    }

    func testOpenShellRefusesMissingDistroBeforeTerminalLaunch() throws {
        let fixture = try Fixture.make()
        let home = MSLHome(root: fixture.root.appendingPathComponent("home"))
        XCTAssertThrowsError(try LauncherRuntime.openShell(home: home, name: "missing"))
    }

    private func appScript(_ app: URL) -> URL {
        return app.appendingPathComponent("Contents/MacOS/msl-launcher")
    }

    private func appIcon(_ app: URL) -> URL {
        return app.appendingPathComponent("Contents/Resources/msl-distro.icns")
    }

    private func infoPlist(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(value as? [String: Any])
    }
}

private struct Fixture {
    let root: URL
    let apps: URL
    let entry: DistroEntry
    let store: LauncherStore

    static func make(
        root providedRoot: URL? = nil, apps providedApps: URL? = nil
    ) throws -> Fixture {
        let root =
            providedRoot
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-launcher-tests-\(UUID().uuidString)")
        let apps = providedApps ?? root.appendingPathComponent("Applications")
        let home = MSLHome(root: root.appendingPathComponent("home"))
        try home.ensureDirectories()
        let entry = DistroEntry(
            name: "ubuntu", image: "ubuntu.img", hostname: "ubuntu", createdAt: "now")
        var registry = Registry()
        try registry.add(entry)
        try registry.save(to: home.registryURL)
        let store = LauncherStore(
            home: home, applicationsDirectory: apps, mslExecutable: "/usr/bin/true",
            signBundles: false)
        return Fixture(root: root, apps: apps, entry: entry, store: store)
    }
}
