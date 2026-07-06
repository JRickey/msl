import Foundation
import XCTest

@testable import MSLCore

final class MSLHomeResolveTests: XCTestCase {
    func testEnvOverrideWins() {
        let home = MSLHome.resolve(env: ["MSL_HOME": "/opt/msl"], homeDirectory: "/Users/x")
        XCTAssertEqual(home.root.path, "/opt/msl")
    }

    func testEmptyEnvFallsBackToDotMsl() {
        let home = MSLHome.resolve(env: ["MSL_HOME": ""], homeDirectory: "/Users/x")
        XCTAssertEqual(home.root.path, "/Users/x/.msl")
    }

    func testDefaultHomeIsDotMsl() {
        let home = MSLHome.resolve(env: [:], homeDirectory: "/Users/x")
        XCTAssertEqual(home.root.path, "/Users/x/.msl")
    }

    func testDerivedPaths() {
        let home = MSLHome(root: URL(fileURLWithPath: "/h"))
        XCTAssertEqual(home.kernelPath, "/h/kernel")
        XCTAssertEqual(home.initramfsPath, "/h/initramfs.cpio")
        XCTAssertEqual(home.builderInitramfsPath, "/h/builder-initramfs.cpio")
        XCTAssertEqual(home.registryURL.path, "/h/registry.json")
        XCTAssertEqual(home.imageURL(name: "ubuntu").path, "/h/distros/ubuntu.img")
    }
}

final class MSLHomePrecedenceTests: XCTestCase {
    func testFlagOverridesEverything() {
        let home = MSLHome(root: URL(fileURLWithPath: "/h"))
        let path = home.resolvePath(
            flag: "/explicit/k", homeCandidate: "/h/kernel", devEnv: "/env/k", devDefault: "kernel")
        XCTAssertEqual(path, "/explicit/k")
    }

    func testHomeCandidateUsedWhenReadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kernel = dir.appendingPathComponent("kernel")
        try Data("k".utf8).write(to: kernel)
        let home = MSLHome(root: dir)
        let path = home.resolvePath(
            flag: nil, homeCandidate: home.kernelPath, devEnv: "/env/k", devDefault: "kernel")
        XCTAssertEqual(path, kernel.path)
    }

    func testDevEnvUsedWhenHomeAbsent() {
        let home = MSLHome(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        let path = home.resolvePath(
            flag: nil, homeCandidate: home.kernelPath, devEnv: "/env/k", devDefault: "kernel")
        XCTAssertEqual(path, "/env/k")
    }

    func testBundledResourceUsedBeforeDevDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-app-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("msl.app/Contents/Resources")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kernel = dir.appendingPathComponent("kernel")
        try Data("k".utf8).write(to: kernel)
        let exe = dir.deletingLastPathComponent().appendingPathComponent("MacOS/msl")
        let path = MSLHome.bundledResourcePath(
            named: "kernel", executablePath: exe.path, bundleResourceURL: nil)
        XCTAssertEqual(path, kernel.path)
    }

    func testBundleResourceURLWinsWhenReadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-resources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let initramfs = dir.appendingPathComponent("initramfs.cpio")
        try Data("i".utf8).write(to: initramfs)
        let path = MSLHome.bundledResourcePath(
            named: "initramfs.cpio", executablePath: nil, bundleResourceURL: dir)
        XCTAssertEqual(path, initramfs.path)
    }

    func testDevDefaultIsLastResort() {
        let home = MSLHome(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        let path = home.resolvePath(
            flag: nil, homeCandidate: home.kernelPath, devEnv: nil, devDefault: "kernel")
        XCTAssertEqual(path, "kernel")
    }

    func testEnsureDirectoriesCreatesStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = MSLHome(root: dir)
        try home.ensureDirectories()
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: home.distrosDirectory.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.logsDirectory.path))
    }
}
