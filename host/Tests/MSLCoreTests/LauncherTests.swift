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
            homeDirectory: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(url.path, "/tmp/msl-apps")
    }

    func testOpenShellRefusesMissingDistroBeforeTerminalLaunch() throws {
        let fixture = try Fixture.make()
        let home = MSLHome(root: fixture.root.appendingPathComponent("home"))
        XCTAssertThrowsError(try LauncherRuntime.openShell(home: home, name: "missing"))
    }

    private func appScript(_ app: URL) -> URL {
        return app.appendingPathComponent("Contents/MacOS/msl-launcher")
    }
}

private struct Fixture {
    let root: URL
    let apps: URL
    let entry: DistroEntry
    let store: LauncherStore

    static func make() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-launcher-tests-\(UUID().uuidString)")
        let apps = root.appendingPathComponent("Applications")
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
