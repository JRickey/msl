import Foundation
import XCTest

@testable import MSLCore

final class BundleSniffTests: XCTestCase {
    func testGzipMagic() {
        let data = Data([0x1F, 0x8B, 0x08, 0x00])
        XCTAssertEqual(BundleSniff.compression(header: data), .gzip)
    }

    func testXzMagic() {
        let data = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00])
        XCTAssertEqual(BundleSniff.compression(header: data), .xz)
    }

    func testUstarAtOffset257() {
        var bytes = [UInt8](repeating: 0, count: 265)
        let magic: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72]
        for idx in 0..<magic.count { bytes[257 + idx] = magic[idx] }
        XCTAssertEqual(BundleSniff.compression(header: Data(bytes)), TarCompression.none)
    }

    func testShortDataFailsUstarCheck() {
        // "ustar" needs 262 bytes; a 260-byte plain header cannot match.
        let data = Data([UInt8](repeating: 0, count: 260))
        XCTAssertNil(BundleSniff.compression(header: data))
    }

    func testTruncatedGzipFails() {
        let data = Data([0x1F])
        XCTAssertNil(BundleSniff.compression(header: data))
    }

    func testEmptyHeaderIsNil() {
        XCTAssertNil(BundleSniff.compression(header: Data()))
    }

    func testGarbageIsNil() {
        let data = Data([UInt8](repeating: 0xAB, count: 512))
        XCTAssertNil(BundleSniff.compression(header: data))
    }
}

final class BundleMetaParseTests: XCTestCase {
    func testBothKeys() throws {
        let meta = try BundleMeta.parse(conf: "[distro]\nname = ubuntu\ndefault-user = jack\n")
        XCTAssertEqual(meta.name, "ubuntu")
        XCTAssertEqual(meta.defaultUser, "jack")
    }

    func testNameOnly() throws {
        let meta = try BundleMeta.parse(conf: "[distro]\nname = alpine\n")
        XCTAssertEqual(meta.name, "alpine")
        XCTAssertNil(meta.defaultUser)
    }

    func testEmptyConfIsAllNil() throws {
        let meta = try BundleMeta.parse(conf: "")
        XCTAssertNil(meta.name)
        XCTAssertNil(meta.defaultUser)
    }

    func testCommentsAndBlankLinesIgnored() throws {
        let conf =
            "# lead comment\n; semicolon comment\n\n[distro]\n\nname = debian\ndefault-user = dev\n"
        let meta = try BundleMeta.parse(conf: conf)
        XCTAssertEqual(meta.name, "debian")
        XCTAssertEqual(meta.defaultUser, "dev")
    }

    func testUnknownSectionIgnored() throws {
        let conf = "[other]\nname = ignored\n[distro]\nname = real\n"
        let meta = try BundleMeta.parse(conf: conf)
        XCTAssertEqual(meta.name, "real")
    }

    func testUnknownKeyIgnored() throws {
        let conf = "[distro]\nicon = foo.png\nname = kept\n"
        let meta = try BundleMeta.parse(conf: conf)
        XCTAssertEqual(meta.name, "kept")
    }

    func testDuplicateKeyLastWins() throws {
        let conf = "[distro]\nname = first\nname = second\n"
        let meta = try BundleMeta.parse(conf: conf)
        XCTAssertEqual(meta.name, "second")
    }

    func testKeyOutsideDistroSectionIgnored() throws {
        let conf = "name = loose\n[distro]\ndefault-user = only\n"
        let meta = try BundleMeta.parse(conf: conf)
        XCTAssertNil(meta.name)
        XCTAssertEqual(meta.defaultUser, "only")
    }

    func testInvalidNameThrows() {
        XCTAssertThrowsError(try BundleMeta.parse(conf: "[distro]\nname = Bad_Name\n"))
    }

    func testInvalidUserThrows() {
        XCTAssertThrowsError(try BundleMeta.parse(conf: "[distro]\ndefault-user = 9bad\n"))
    }

    func testOverLineCapThrows() {
        let body = String(repeating: "\n", count: 5000)
        XCTAssertThrowsError(try BundleMeta.parse(conf: body))
    }

    func testAtLineCapAccepted() throws {
        let body = "[distro]\nname = ok\n" + String(repeating: "\n", count: 4000)
        let meta = try BundleMeta.parse(conf: body)
        XCTAssertEqual(meta.name, "ok")
    }
}

final class BundleMetaRenderTests: XCTestCase {
    func testRenderWithUser() {
        let out = BundleMeta.render(name: "ubuntu", defaultUser: "jack")
        XCTAssertEqual(out, "[distro]\nname = ubuntu\ndefault-user = jack\n")
    }

    func testRenderWithoutUser() {
        let out = BundleMeta.render(name: "alpine", defaultUser: nil)
        XCTAssertEqual(out, "[distro]\nname = alpine\n")
    }

    func testRoundTripWithUser() throws {
        let out = BundleMeta.render(name: "fedora", defaultUser: "dev")
        let meta = try BundleMeta.parse(conf: out)
        XCTAssertEqual(meta.name, "fedora")
        XCTAssertEqual(meta.defaultUser, "dev")
    }

    func testRoundTripWithoutUser() throws {
        let out = BundleMeta.render(name: "arch", defaultUser: nil)
        let meta = try BundleMeta.parse(conf: out)
        XCTAssertEqual(meta.name, "arch")
        XCTAssertNil(meta.defaultUser)
    }
}

final class BundleMetaWSLTests: XCTestCase {
    func testDefaultNameFoldsToMSLGrammar() throws {
        let meta = try BundleMeta.parseWSL(
            conf: "[oobe]\ndefaultName = Debian\ndefaultUid = 1000\n")
        XCTAssertEqual(meta.name, "debian")
        XCTAssertNil(meta.defaultUser)
    }

    func testInvalidDefaultNameReadsAsAbsent() throws {
        let meta = try BundleMeta.parseWSL(conf: "[oobe]\ndefaultName = Not A Name!\n")
        XCTAssertNil(meta.name)
    }

    func testDefaultNameOutsideOobeIgnored() throws {
        let meta = try BundleMeta.parseWSL(conf: "[shortcut]\ndefaultName = debian\n")
        XCTAssertNil(meta.name)
    }

    func testOverLineCapThrows() {
        let conf = String(repeating: "\n", count: 4097)
        XCTAssertThrowsError(try BundleMeta.parseWSL(conf: conf))
    }
}

final class BundleReaderTests: XCTestCase {
    private func makeArchive(
        confBody: String?, confMemberDir: String, gzip: Bool, in dir: URL,
        confFilename: String = "msl-distribution.conf", suffix: String = "msl"
    ) throws -> URL {
        let root = dir.appendingPathComponent("root")
        let etc = root.appendingPathComponent("etc")
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("marker"))
        if let body = confBody {
            try Data(body.utf8).write(to: etc.appendingPathComponent(confFilename))
        }
        let out = dir.appendingPathComponent(gzip ? "bundle.\(suffix)" : "bundle-plain.\(suffix)")
        var args = [gzip ? "-czf" : "-cf", out.path, "-C", root.path]
        args.append(confMemberDir)
        args.append("marker")
        try runTar(args)
        return out
    }

    private func runTar(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MSLError.io("tar failed building fixture (exit \(process.terminationStatus))")
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-bundle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testPlainArchiveConfUnderDotEtc() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(
            confBody: "[distro]\nname = fixture\ndefault-user = dev\n",
            confMemberDir: "./etc", gzip: false, in: dir)
        let info = try BundleReader.read(path: archive.path)
        XCTAssertEqual(info.compression, TarCompression.none)
        XCTAssertEqual(info.meta.name, "fixture")
        XCTAssertEqual(info.meta.defaultUser, "dev")
    }

    func testGzipArchiveConfUnderEtc() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(
            confBody: "[distro]\nname = gzfixture\n",
            confMemberDir: "etc", gzip: true, in: dir)
        let info = try BundleReader.read(path: archive.path)
        XCTAssertEqual(info.compression, .gzip)
        XCTAssertEqual(info.meta.name, "gzfixture")
        XCTAssertNil(info.meta.defaultUser)
    }

    func testArchiveWithoutConfIsEmptyMeta() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(
            confBody: nil, confMemberDir: "./etc", gzip: false, in: dir)
        let info = try BundleReader.read(path: archive.path)
        XCTAssertEqual(info.compression, TarCompression.none)
        XCTAssertNil(info.meta.name)
        XCTAssertNil(info.meta.defaultUser)
    }

    func testWslArchiveReadsOobeDefaultName() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive(
            confBody: "[oobe]\ndefaultName = Debian\n",
            confMemberDir: "etc", gzip: true, in: dir,
            confFilename: "wsl-distribution.conf", suffix: "wsl")
        let info = try BundleReader.read(path: archive.path)
        XCTAssertEqual(info.compression, .gzip)
        XCTAssertEqual(info.meta.name, "debian")
        XCTAssertNil(info.meta.defaultUser)
    }

    func testMslConfWinsOverWslConf() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root")
        let etc = root.appendingPathComponent("etc")
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        try Data("[distro]\nname = mslwins\n".utf8)
            .write(to: etc.appendingPathComponent("msl-distribution.conf"))
        try Data("[oobe]\ndefaultName = wslname\n".utf8)
            .write(to: etc.appendingPathComponent("wsl-distribution.conf"))
        let out = dir.appendingPathComponent("both.wsl")
        try runTar(["-czf", out.path, "-C", root.path, "etc"])
        let info = try BundleReader.read(path: out.path)
        XCTAssertEqual(info.meta.name, "mslwins")
    }

    func testNonTarGarbageRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("junk.msl")
        try Data([UInt8](repeating: 0x42, count: 600)).write(to: bogus)
        XCTAssertThrowsError(try BundleReader.read(path: bogus.path)) { error in
            guard case MSLError.invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func testUnreadablePathRejected() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).msl").path
        XCTAssertThrowsError(try BundleReader.read(path: missing))
    }
}
