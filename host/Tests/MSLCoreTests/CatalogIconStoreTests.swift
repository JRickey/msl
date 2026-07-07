import CryptoKit
import Foundation
import XCTest

@testable import MSLCore

final class CatalogIconStoreTests: XCTestCase {
    func testCachedPNGIconIsVerifiedAndConvertedToICNS() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-icon-store-tests-\(UUID().uuidString)")
        let home = MSLHome(root: root.appendingPathComponent("home"))
        let png = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
            ))
        let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let cached = home.catalogIconCacheDirectory
            .appendingPathComponent(sha)
            .appendingPathComponent("icon.png")
        try FileManager.default.createDirectory(
            at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: cached)
        let resolved = makeResolved(iconSHA: sha, sizeBytes: UInt64(png.count))
        let recorder = ProgressRecorder()

        let icon = try XCTUnwrap(
            CatalogIconStore(home: home).icon(for: resolved) { event in
                recorder.append(event)
            })

        XCTAssertEqual(icon.pathExtension, "icns")
        let data = try Data(contentsOf: icon)
        XCTAssertEqual(String(data: Data(data.prefix(4)), encoding: .ascii), "icns")
        XCTAssertTrue(recorder.events().contains(.cacheHit(path: cached.path)))
    }

    func testCachedSVGIconIsVerifiedAndConvertedToICNS() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msl-svg-icon-store-tests-\(UUID().uuidString)")
        let home = MSLHome(root: root.appendingPathComponent("home"))
        defer { try? FileManager.default.removeItem(at: root) }
        let svgText =
            ##"<svg fill="#E95420" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">"##
            + #"<path d="M12 2 22 22H2z"/></svg>"#
        let svg = Data(svgText.utf8)
        let sha = SHA256.hash(data: svg).map { String(format: "%02x", $0) }.joined()
        let cached = home.catalogIconCacheDirectory
            .appendingPathComponent(sha)
            .appendingPathComponent("ubuntu.svg")
        try FileManager.default.createDirectory(
            at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try svg.write(to: cached)
        let icon = CatalogIcon(
            kind: .svg, url: "https://example.invalid/ubuntu", sha256: sha,
            sizeBytes: UInt64(svg.count), backgroundHex: "E95420")

        let converted = try CatalogIconStore(home: home).icon(icon, label: "ubuntu")

        XCTAssertEqual(converted.pathExtension, "icns")
        XCTAssertTrue(converted.lastPathComponent.contains("E95420"))
        let data = try Data(contentsOf: converted)
        XCTAssertEqual(String(data: Data(data.prefix(4)), encoding: .ascii), "icns")
    }

    private func makeResolved(iconSHA: String, sizeBytes: UInt64) -> CatalogResolved {
        let artifact = CatalogArtifact(
            arch: "arm64", kind: .rootfsTar, compression: .xz,
            url: "https://example.invalid/rootfs.tar.xz",
            sha256: String(repeating: "b", count: 64), sizeBytes: 1024)
        let icon = CatalogIcon(
            kind: .png, url: "https://example.invalid/icon.png", sha256: iconSHA,
            sizeBytes: sizeBytes)
        let version = CatalogVersion(
            version: "1", aliases: [], status: .recommended, artifact: artifact, icon: icon,
            defaultUser: nil, imageSizeGiB: 8, notes: "test")
        let family = CatalogFamily(
            name: "test", friendlyName: "Test", defaultVersion: "1", aliases: [],
            versions: [version])
        return CatalogResolved(family: family, version: version, artifact: artifact)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CatalogDownloadProgress] = []

    func append(_ event: CatalogDownloadProgress) {
        lock.lock()
        values.append(event)
        lock.unlock()
    }

    func events() -> [CatalogDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
